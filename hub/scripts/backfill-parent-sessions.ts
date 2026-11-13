#!/usr/bin/env bun
import { Database } from 'bun:sqlite'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import {
    applyHistoricalParentBackfill,
    findHistoricalParentBackfillCandidates
} from '../src/store/backfillParentSessions'

function parseArgs(argv: string[]): { dbPath: string; mode: 'dry-run' | 'apply' } {
    let dbPath = join(homedir(), '.hapi', 'hapi.db')
    let mode: 'dry-run' | 'apply' = 'dry-run'

    for (let i = 0; i < argv.length; i += 1) {
        const arg = argv[i]
        if (arg === '--db') {
            const next = argv[i + 1]
            if (!next) {
                throw new Error('Missing value for --db')
            }
            dbPath = resolve(next)
            i += 1
        } else if (arg === '--apply') {
            mode = 'apply'
        } else if (arg === '--dry-run') {
            mode = 'dry-run'
        } else if (arg === '--help' || arg === '-h') {
            console.log('Usage: bun hub/scripts/backfill-parent-sessions.ts [--db <path>] [--dry-run | --apply]')
            process.exit(0)
        } else {
            throw new Error(`Unknown argument: ${arg}`)
        }
    }

    return { dbPath, mode }
}

function main(): void {
    const { dbPath, mode } = parseArgs(process.argv.slice(2))
    const db = new Database(dbPath, { create: false })
    try {
        if (mode === 'dry-run') {
            db.exec('PRAGMA query_only = ON')
            const plan = findHistoricalParentBackfillCandidates(db)
            console.log(JSON.stringify({ mode, dbPath, ...plan }, null, 2))
            return
        }
        const result = applyHistoricalParentBackfill(db)
        console.log(JSON.stringify({ mode, dbPath, ...result }, null, 2))
    } finally {
        db.close()
    }
}

main()
