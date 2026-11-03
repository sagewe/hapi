import { z } from 'zod'
export const PreviewTargetSchema = z.object({
    host: z.enum(['localhost', '127.0.0.1', '::1']),
    port: z.number().int().min(1024).max(65535),
})
export const PreviewOpenSchema = PreviewTargetSchema.extend({ sessionId: z.string().min(1).max(256) })
export const PreviewCloseSchema = z.object({ sessionId: z.string().min(1).max(256), id: z.string().uuid() })
export const PreviewLeaseSchema = z.object({
    id: z.string().uuid(), origin: z.string().url().startsWith('https://'),
    username: z.literal('preview'), password: z.string().min(32), expiresAt: z.number().int(),
})
export type PreviewLease = z.infer<typeof PreviewLeaseSchema>
export type PreviewOpen = z.infer<typeof PreviewOpenSchema>
