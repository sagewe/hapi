import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { buildAgyAcpPromptContent } from './agyPromptContent';

const TINY_PNG = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
]);

const tempDirs: string[] = [];

function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), 'hapi-agy-prompt-'));
    tempDirs.push(dir);
    return dir;
}

afterEach(() => {
    while (tempDirs.length > 0) {
        rmSync(tempDirs.pop()!, { recursive: true, force: true });
    }
});

describe('buildAgyAcpPromptContent', () => {
    it('inlines valid image attachments as ACP image blocks while preserving non-image @path references', async () => {
        const dir = makeTempDir();
        const imgPath = join(dir, 'photo.png');
        const pdfPath = join(dir, 'doc.pdf');
        const missingImg = join(dir, 'missing.png');
        writeFileSync(imgPath, TINY_PNG);
        writeFileSync(pdfPath, '%PDF-1.4');

        const formattedText = `@${imgPath} @${pdfPath} @${missingImg}\n\n看一下这张图和文档`;
        const blocks = await buildAgyAcpPromptContent(formattedText, [
            { id: '1', filename: 'photo.png', path: imgPath, mimeType: 'image/png', size: TINY_PNG.length },
            { id: '2', filename: 'doc.pdf', path: pdfPath, mimeType: 'application/pdf', size: 8 },
            { id: '3', filename: 'missing.png', path: missingImg, mimeType: 'image/png', size: 10 },
        ]);

        expect(blocks).toEqual([
            { type: 'image', mimeType: 'image/png', data: TINY_PNG.toString('base64') },
            {
                type: 'text',
                text: `[Attached image: ${imgPath}] @${pdfPath} @${missingImg}\n\n看一下这张图和文档`,
            },
        ]);
    });

    it('returns a plain text block when no attachments are present', async () => {
        expect(await buildAgyAcpPromptContent('hello')).toEqual([{ type: 'text', text: 'hello' }]);
    });
});
