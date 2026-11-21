import { randomUUID } from 'node:crypto';
import { realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { AgentMessage } from '@/agent/types';
import {
    detectImageMimeType,
    MAX_GENERATED_IMAGE_BYTES,
    readBoundedRegularFile,
    registerGeneratedImage,
} from '@/modules/common/generatedImages';
import { sessionTagsInstruction } from '@/modules/common/sessionTagTools';
import { trimIdent } from '@/utils/trimIdent';

export const AGY_HAPI_MCP_PROMPT = trimIdent(`
    You are running inside HAPI. The "hapi" MCP server provides tools for the human user in HAPI mobile/web chat:
    - When you create, render, or find a local image file (including files in your artifact/brain directory or the workspace) that the human user should see, call the "hapi" MCP tool "display_image" with its absolute filesystem path (and an optional concise title) so HAPI displays it inline.
    - Use "display_video" for local mp4/webm recordings and "display_media" for audio or other local files to send to the user.
    - "display_image" only shows the image to the human user; it does not provide image input to you.
    - ${sessionTagsInstruction('list_tags', 'change_title')}
`);

export interface MarkdownImageRef {
    alt: string;
    destination: string;
}

const FENCE_RE = /^ {0,3}(`{3,}|~{3,})(.*)$/;

function stripCodeOutsideProse(markdown: string): string {
    const lines = markdown.split(/\r?\n/);
    const out: string[] = [];
    let fenceChar: string | null = null;
    let fenceLength = 0;

    for (const line of lines) {
        const match = FENCE_RE.exec(line);
        if (match) {
            const marker = match[1];
            const rest = match[2];
            if (!fenceChar) {
                fenceChar = marker[0];
                fenceLength = marker.length;
                continue;
            }
            if (marker[0] === fenceChar && marker.length >= fenceLength && rest.trim() === '') {
                fenceChar = null;
                fenceLength = 0;
                continue;
            }
        }
        if (!fenceChar) {
            out.push(line);
        }
    }

    // Mask inline code spans (`...`, ``...``) so documented examples do not trigger.
    return out.join('\n').replace(/(`+)([\s\S]*?)\1/g, '');
}

/**
 * Extract Markdown image references `![alt](destination)` outside fenced code
 * blocks and inline code spans. Supports `<destination>` with spaces, optional
 * titles, and balanced parentheses inside destinations.
 */
export function extractMarkdownImageReferences(markdown: string): MarkdownImageRef[] {
    const prose = stripCodeOutsideProse(markdown);
    const refs: MarkdownImageRef[] = [];

    let i = 0;
    while (i < prose.length) {
        const bang = prose.indexOf('![', i);
        if (bang < 0) break;
        if (bang > 0 && prose[bang - 1] === '\\') {
            i = bang + 2;
            continue;
        }

        // Scan alt text up to unescaped ']'.
        let altEnd = bang + 2;
        let bracketDepth = 0;
        while (altEnd < prose.length) {
            const ch = prose[altEnd];
            if (ch === '\\') {
                altEnd += 2;
                continue;
            }
            if (ch === '[') {
                bracketDepth++;
            } else if (ch === ']') {
                if (bracketDepth === 0) break;
                bracketDepth--;
            }
            altEnd++;
        }
        if (altEnd >= prose.length || prose[altEnd] !== ']' || prose[altEnd + 1] !== '(') {
            i = bang + 2;
            continue;
        }

        const alt = prose.slice(bang + 2, altEnd).trim();
        let pos = altEnd + 2;
        while (pos < prose.length && (prose[pos] === ' ' || prose[pos] === '\t')) {
            pos++;
        }

        let destination = '';
        if (prose[pos] === '<') {
            const closeAngle = prose.indexOf('>', pos + 1);
            if (closeAngle < 0) {
                i = pos;
                continue;
            }
            destination = prose.slice(pos + 1, closeAngle).trim();
            pos = closeAngle + 1;
            const closeParen = prose.indexOf(')', pos);
            if (closeParen < 0) {
                i = pos;
                continue;
            }
            pos = closeParen + 1;
        } else {
            const destStart = pos;
            let parenDepth = 0;
            let closed = false;
            while (pos < prose.length) {
                const ch = prose[pos];
                if (ch === '\\' && pos + 1 < prose.length) {
                    pos += 2;
                    continue;
                }
                if (ch === '(') {
                    parenDepth++;
                    pos++;
                    continue;
                }
                if (ch === ')') {
                    if (parenDepth === 0) {
                        destination = prose.slice(destStart, pos).trim();
                        pos++;
                        closed = true;
                        break;
                    }
                    parenDepth--;
                    pos++;
                    continue;
                }
                if ((ch === ' ' || ch === '\t' || ch === '\n') && parenDepth === 0) {
                    // Destination ends; optional title may follow before ')'.
                    destination = prose.slice(destStart, pos).trim();
                    const closeParen = prose.indexOf(')', pos);
                    if (closeParen >= 0) {
                        pos = closeParen + 1;
                        closed = true;
                    }
                    break;
                }
                pos++;
            }
            if (!closed) {
                i = altEnd + 2;
                continue;
            }
        }

        if (destination) {
            refs.push({ alt, destination });
        }
        i = pos;
    }

    return refs;
}

function stripQueryAndFragment(value: string): string {
    const hashIdx = value.indexOf('#');
    const queryIdx = value.indexOf('?');
    const cut = hashIdx < 0
        ? queryIdx
        : queryIdx < 0
            ? hashIdx
            : Math.min(hashIdx, queryIdx);
    return cut < 0 ? value : value.slice(0, cut);
}

function toLocalCandidatePath(destination: string, workspaceDir?: string | null): string | null {
    const raw = destination.trim();
    if (!raw) return null;

    if (/^file:\/\//i.test(raw)) {
        try {
            return fileURLToPath(stripQueryAndFragment(raw));
        } catch {
            return null;
        }
    }

    // Reject remote URLs and non-file schemes (http, https, data, javascript, etc.).
    if (raw.startsWith('//') || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(raw)) {
        return null;
    }

    const stripped = stripQueryAndFragment(raw);
    let decoded = stripped;
    try {
        decoded = decodeURIComponent(stripped);
    } catch {
        // Keep raw if percent sequence is literal.
    }
    if (!decoded) return null;

    if (decoded === '~' || decoded.startsWith('~/')) {
        return resolve(homedir(), decoded.slice(2));
    }

    if (isAbsolute(decoded)) {
        return decoded;
    }

    if (!workspaceDir) {
        return null;
    }

    return resolve(workspaceDir, decoded);
}

function isStrictlyInside(realPath: string, realRoot: string): boolean {
    const rel = relative(realRoot, realPath);
    return rel !== '' && rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

/**
 * Resolve a Markdown image destination to a real local path ONLY when it lies
 * strictly inside the current agy session's brain directory or the session's
 * workspace directory (after symlink resolution).
 */
export async function resolveAllowedAgyImagePath(
    destination: string,
    roots: { workspaceDir?: string | null; sessionBrainDir?: string | null }
): Promise<string | null> {
    const candidate = toLocalCandidatePath(destination, roots.workspaceDir);
    if (!candidate) return null;

    let realCandidate: string;
    try {
        realCandidate = await realpath(candidate);
    } catch {
        return null;
    }

    const allowedRoots = [roots.sessionBrainDir, roots.workspaceDir].filter(
        (root): root is string => typeof root === 'string' && root.trim().length > 0
    );

    for (const root of allowedRoots) {
        try {
            const realRoot = await realpath(root);
            if (isStrictlyInside(realCandidate, realRoot)) {
                return realCandidate;
            }
        } catch {
            // Root directory may not exist yet (e.g. brand-new brain directory).
        }
    }

    return null;
}

function sanitizeImageLabel(alt: string, realPath: string): string | undefined {
    const cleaned = alt
        .replace(/[\r\n\t]+/g, ' ')
        .replace(/[\\/]+/g, ' ')
        .replace(/[\x00-\x1f\x7f]/g, '')
        .trim()
        .slice(0, 120);
    if (!cleaned || cleaned === '.' || cleaned === '..') {
        return basename(realPath) || undefined;
    }
    return cleaned;
}

export async function registerAgyMarkdownImages(args: {
    text: string;
    workspaceDir?: string | null;
    sessionBrainDir?: string | null;
    alreadyDisplayedPaths: Set<string>;
    onImage: (message: Extract<AgentMessage, { type: 'generated_image' }>) => void;
}): Promise<void> {
    const refs = extractMarkdownImageReferences(args.text);
    if (refs.length === 0) return;

    for (const ref of refs) {
        const realPath = await resolveAllowedAgyImagePath(ref.destination, {
            workspaceDir: args.workspaceDir,
            sessionBrainDir: args.sessionBrainDir,
        });
        if (!realPath || args.alreadyDisplayedPaths.has(realPath)) {
            continue;
        }
        // Reserve immediately before async file read so concurrent flushes do
        // not emit the same image twice.
        args.alreadyDisplayedPaths.add(realPath);
        try {
            const bytes = await readBoundedRegularFile(realPath, MAX_GENERATED_IMAGE_BYTES);
            const mimeType = detectImageMimeType(bytes);
            if (!mimeType) {
                continue;
            }
            const media = registerGeneratedImage({
                id: randomUUID(),
                path: realPath,
                fileName: sanitizeImageLabel(ref.alt, realPath),
                mimeType,
                bytes,
            });
            args.onImage({
                type: 'generated_image',
                imageId: media.id,
                fileName: media.fileName,
                mimeType: media.mimeType,
            });
        } catch {
            // Ignore unreadable / oversized / non-image targets; original Markdown stays intact.
        }
    }
}
