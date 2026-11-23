import { afterEach, expect, test } from 'bun:test'
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Hono } from 'hono'
import { SignJWT } from 'jose'
import { createAuthMiddleware, type WebAppEnv } from '../middleware/auth'
import { createAndroidUpdateRoutes, validApkFilename } from './androidUpdates'
const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(p => rm(p, { recursive: true, force: true }))) })
async function fixture() {
    const root = await mkdtemp(join(tmpdir(), 'android-release-')); roots.push(root)
    const key = new TextEncoder().encode('test-only-android-release-jwt-secret')
    const app = new Hono<WebAppEnv>()
    app.use('/api/*', createAuthMiddleware(key)); app.route('/api', createAndroidUpdateRoutes(root))
    const token = await new SignJWT({ uid: 1, ns: 'default' }).setProtectedHeader({ alg: 'HS256' }).setExpirationTime('1h').sign(key)
    const get = (path: string) => app.request('/api/app-updates/android/' + path, { headers: { Authorization: 'Bearer ' + token } })
    return { app, root, get }
}
test('anonymous latest and downloads require JWT', async () => {
    const { app } = await fixture()
    for (const path of ['latest', 'download/test.apk']) expect((await app.request('/api/app-updates/android/' + path)).status).toBe(401)
})
test('missing publication is read-only 404', async () => {
    const { root, get } = await fixture()
    expect((await get('latest')).status).toBe(404)
    expect(await Bun.file(join(root, 'android-releases/latest.json')).exists()).toBe(false)
})
test('strict filename whitelist rejects traversal and non APK files', async () => {
    const { get } = await fixture()
    for (const name of ['../a.apk','a..apk','a/b.apk','a\\b.apk','a.zip','x.apk.exe','%2e%2e.apk']) expect(validApkFilename(name)).toBe(false)
    for (const path of ['download/a..apk','download/a%2Fb.apk','download/x.zip','download/%252e%252e.apk']) expect([400,404]).toContain((await get(path)).status)
})
test('metadata and streaming APK response match publication; symlinks refused', async () => {
    const { root, get } = await fixture(); const dir = join(root,'android-releases'); await mkdir(dir)
    const release = { packageName:'com.sagewe.hapi.compliance', versionCode:2, versionName:'0.34.3', fileName:'QiqiWork-2.apk', sha256:'a'.repeat(64), size:3, releaseNotes:'更新', publishedAt:'2026-11-23T00:00:00Z', downloadPath:'/api/app-updates/android/download/QiqiWork-2.apk' }
    await writeFile(join(dir, release.fileName),'apk'); await writeFile(join(dir,'latest.json'),JSON.stringify(release))
    const latest = await get('latest'); expect(latest.status).toBe(200); expect(await latest.json()).toEqual(release)
    const apk = await get('download/'+release.fileName); expect(apk.status).toBe(200); expect(apk.headers.get('content-type')).toBe('application/vnd.android.package-archive'); expect(await apk.text()).toBe('apk')
    await symlink(join(dir,release.fileName),join(dir,'linked.apk')); expect((await get('download/linked.apk')).status).toBe(404)
})
