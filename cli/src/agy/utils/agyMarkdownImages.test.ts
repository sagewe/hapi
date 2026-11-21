import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
    extractMarkdownImageReferences,
    registerAgyMarkdownImages,
    resolveAllowedAgyImagePath,
} from './agyMarkdownImages';
import { clearGeneratedImages, getGeneratedImage } from '@/modules/common/generatedImages';
import type { AgentMessage } from '@/agent/types';

// Minimal valid 1x1 PNG header + bytes recognized by detectImageMimeType.
const TINY_PNG = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
]);

const tempDirs: string[] = [];

function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), 'hapi-agy-md-img-'));
    tempDirs.push(dir);
    return dir;
}

afterEach(() => {
    clearGeneratedImages();
    while (tempDirs.length > 0) {
        const dir = tempDirs.pop()!;
        rmSync(dir, { recursive: true, force: true });
    }
});

describe('extractMarkdownImageReferences', () => {
    it('extracts standard, angle-bracketed, and titled image links while ignoring code blocks and inline code', () => {
        const md = [
            'Intro `![inline-code](/tmp/ignore.png)` text.',
            '```markdown',
            '![fenced](/tmp/ignore2.png)',
            '```',
            '![MyDots 空白首屏优化方案对比](/Users/sage/.gemini/antigravity-cli/brain/abc/welcome-mockups.png)',
            '![With Spaces](</tmp/my folder/shot (1).png> "Title")',
            '![Relative](docs/diagram.png "Diagram")',
        ].join('\n');

        expect(extractMarkdownImageReferences(md)).toEqual([
            { alt: 'MyDots 空白首屏优化方案对比', destination: '/Users/sage/.gemini/antigravity-cli/brain/abc/welcome-mockups.png' },
            { alt: 'With Spaces', destination: '/tmp/my folder/shot (1).png' },
            { alt: 'Relative', destination: 'docs/diagram.png' },
        ]);
    });
});

describe('resolveAllowedAgyImagePath & registerAgyMarkdownImages', () => {
    it('registers images from the current session brain directory and workspace, rejecting outside paths and symlink escapes', async () => {
        const root = makeTempDir();
        const workspaceDir = join(root, 'workspace');
        const sessionBrainDir = join(root, 'brain', 'session-1');
        const otherBrainDir = join(root, 'brain', 'session-2');
        const outsideDir = join(root, 'outside');
        mkdirSync(workspaceDir, { recursive: true });
        mkdirSync(sessionBrainDir, { recursive: true });
        mkdirSync(otherBrainDir, { recursive: true });
        mkdirSync(outsideDir, { recursive: true });

        const brainPng = join(sessionBrainDir, 'welcome-mockups.png');
        const workspacePng = join(workspaceDir, 'mockup.png');
        const otherBrainPng = join(otherBrainDir, 'secret.png');
        const outsidePng = join(outsideDir, 'secret.png');
        const symlinkEscape = join(sessionBrainDir, 'escape.png');
        const nonImage = join(sessionBrainDir, 'notes.png');

        writeFileSync(brainPng, TINY_PNG);
        writeFileSync(workspacePng, TINY_PNG);
        writeFileSync(otherBrainPng, TINY_PNG);
        writeFileSync(outsidePng, TINY_PNG);
        writeFileSync(nonImage, 'not really a png');
        symlinkSync(outsidePng, symlinkEscape);

        expect(await resolveAllowedAgyImagePath(brainPng, { workspaceDir, sessionBrainDir })).not.toBeNull();
        expect(await resolveAllowedAgyImagePath(`file://${brainPng}`, { workspaceDir, sessionBrainDir })).not.toBeNull();
        expect(await resolveAllowedAgyImagePath('mockup.png', { workspaceDir, sessionBrainDir })).not.toBeNull();
        expect(await resolveAllowedAgyImagePath(otherBrainPng, { workspaceDir, sessionBrainDir })).toBeNull();
        expect(await resolveAllowedAgyImagePath(outsidePng, { workspaceDir, sessionBrainDir })).toBeNull();
        expect(await resolveAllowedAgyImagePath(symlinkEscape, { workspaceDir, sessionBrainDir })).toBeNull();
        expect(await resolveAllowedAgyImagePath('https://example.com/a.png', { workspaceDir, sessionBrainDir })).toBeNull();

        const emitted: Array<Extract<AgentMessage, { type: 'generated_image' }>> = [];
        const alreadyDisplayedPaths = new Set<string>();

        await registerAgyMarkdownImages({
            text: [
                `![MyDots 方案对比](${brainPng})`,
                `![Duplicate](${brainPng})`,
                `![Workspace Shot](mockup.png)`,
                `![Other Session](${otherBrainPng})`,
                `![Fake PNG](${nonImage})`,
            ].join('\n\n'),
            workspaceDir,
            sessionBrainDir,
            alreadyDisplayedPaths,
            onImage: (msg) => emitted.push(msg),
        });

        expect(emitted).toHaveLength(2);
        expect(emitted[0].fileName).toBe('MyDots 方案对比.png');
        expect(emitted[0].mimeType).toBe('image/png');
        expect(getGeneratedImage(emitted[0].imageId)?.content).toEqual(TINY_PNG);
        expect(emitted[1].fileName).toBe('Workspace Shot.png');
    });

    it('skips images already emitted by display_image in the same turn', async () => {
        const root = makeTempDir();
        const sessionBrainDir = join(root, 'brain', 'session-1');
        mkdirSync(sessionBrainDir, { recursive: true });
        const brainPng = join(sessionBrainDir, 'welcome-mockups.png');
        writeFileSync(brainPng, TINY_PNG);

        const realBrainPng = await resolveAllowedAgyImagePath(brainPng, { sessionBrainDir });
        expect(realBrainPng).not.toBeNull();

        const alreadyDisplayedPaths = new Set<string>([realBrainPng!]);
        const emitted: Array<Extract<AgentMessage, { type: 'generated_image' }>> = [];

        await registerAgyMarkdownImages({
            text: `![Already shown](${brainPng})`,
            sessionBrainDir,
            alreadyDisplayedPaths,
            onImage: (msg) => emitted.push(msg),
        });

        expect(emitted).toHaveLength(0);
    });
});
