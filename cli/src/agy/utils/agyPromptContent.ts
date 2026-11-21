import type { AttachmentMetadata } from '@/api/types';
import type { PromptContent } from '@/agent/types';
import { detectImageMimeType, readBoundedRegularFile } from '@/modules/common/generatedImages';

const MAX_INLINE_PROMPT_IMAGE_BYTES = 20 * 1024 * 1024;
const ACP_SUPPORTED_PROMPT_IMAGE_MIMES = new Set([
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
]);

function escapeRegExp(value: string): string {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Build ACP `session/prompt` content blocks for an Antigravity turn.
 *
 * Image attachments (PNG/JPEG/GIF/WebP up to 20 MiB) are inlined directly as
 * ACP `image` blocks so the model sees them immediately without an extra
 * `read_file` tool round-trip. Their original `@<path>` tokens in the formatted
 * text are rewritten to `[Attached image: <path>]` so the file path remains
 * available if the user asks to save/copy/edit the file, while avoiding a
 * redundant `@file` expansion. Non-image or unreadable attachments keep their
 * original `@<path>` references untouched.
 */
export async function buildAgyAcpPromptContent(
    text: string,
    attachments?: readonly AttachmentMetadata[]
): Promise<PromptContent[]> {
    if (!attachments || attachments.length === 0) {
        return [{ type: 'text', text }];
    }

    const imageBlocks: Array<Extract<PromptContent, { type: 'image' }>> = [];
    const inlinedPaths: string[] = [];
    const seenPaths = new Set<string>();

    for (const attachment of attachments) {
        if (!attachment.path || seenPaths.has(attachment.path)) {
            continue;
        }
        if (attachment.mimeType && !attachment.mimeType.toLowerCase().startsWith('image/')) {
            continue;
        }
        seenPaths.add(attachment.path);
        try {
            const bytes = await readBoundedRegularFile(attachment.path, MAX_INLINE_PROMPT_IMAGE_BYTES);
            const detectedMime = detectImageMimeType(bytes);
            if (!detectedMime || !ACP_SUPPORTED_PROMPT_IMAGE_MIMES.has(detectedMime)) {
                continue;
            }
            imageBlocks.push({
                type: 'image',
                mimeType: detectedMime,
                data: bytes.toString('base64'),
            });
            inlinedPaths.push(attachment.path);
        } catch {
            // Fall back to the existing @path reference in text.
        }
    }

    if (imageBlocks.length === 0) {
        return [{ type: 'text', text }];
    }

    let rewrittenText = text;
    for (const path of inlinedPaths) {
        const pattern = new RegExp(`@${escapeRegExp(path)}(?=\\s|$)`, 'g');
        rewrittenText = rewrittenText.replace(pattern, `[Attached image: ${path}]`);
    }

    return [
        ...imageBlocks,
        { type: 'text', text: rewrittenText },
    ];
}
