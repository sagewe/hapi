import { expect, test } from '@playwright/test'
import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'

test('session and composer pending indicators locate distinct requests', async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem('hapi-lang', 'en'))
    await page.goto('/e2e-fixtures/pending-request-navigation-fixture.html')

    const status = page.getByRole('button', { name: '2 pending requests' })
    await expect(status).toBeVisible()
    await expect(page.getByRole('button', { name: 'permission required' })).toHaveCount(0)

    const listIndicator = page.locator('[data-session-pending-request-id="question"]').first()
    await expect(listIndicator).toBeVisible()
    await listIndicator.click()
    await expect(page.locator('#last-action')).toHaveText('Located request: question')

    await page.reload()
    await status.click()
    const screenshotDir = process.env.HAPI_SCREENSHOT_DIR
    if (screenshotDir) {
        await mkdir(screenshotDir, { recursive: true })
        await page.screenshot({ path: resolve(screenshotDir, 'pending-request-menu.png') })
    }

    await page.getByRole('button').filter({ hasText: 'Needs reply' }).click()
    const card = page.locator('[data-request-card="question"]')
    await expect(page.locator('#last-action')).toHaveText('Located request: question')
    await expect(card).toHaveAttribute('data-selected', 'true')
    await expect(card).toBeInViewport()
    await expect(card.getByText('Which implementation approach should I use?').first()).toBeVisible()

    if (screenshotDir) {
        await page.screenshot({ path: resolve(screenshotDir, 'pending-request-target.png') })
    }
})

test('mobile composer pending menu remains usable without overflow', async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem('hapi-lang', 'en'))
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/e2e-fixtures/pending-request-navigation-fixture.html')

    await page.getByRole('button', { name: '2 pending requests' }).click()
    const menuBox = await page.getByRole('dialog').boundingBox()
    expect(menuBox).not.toBeNull()
    expect(menuBox!.x).toBeCloseTo(12, 0)
    expect(menuBox!.x + menuBox!.width).toBeCloseTo(378, 0)
    await page.getByRole('button').filter({ hasText: 'permission required' }).click()

    const card = page.locator('[data-request-card="approval"]')
    await expect(card).toHaveAttribute('data-selected', 'true')
    await expect(card).toBeInViewport()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)

    const screenshotDir = process.env.HAPI_SCREENSHOT_DIR
    if (screenshotDir) {
        await page.screenshot({ path: resolve(screenshotDir, 'pending-request-mobile.png') })
    }
})

test('loads out-of-window pending context through the real message window and keeps the target in view', async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem('hapi-lang', 'en'))
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/e2e-fixtures/pending-context-fixture.html')
    await expect(page.locator('#window-ids')).toContainText('stored-100')
    await expect(page.locator('#window-ids')).not.toContainText('stored-21')
    await page.getByRole('button', { name: '2 pending requests' }).click()
    await page.getByRole('button', { name: 'Needs reply Which historical approach?' }).click()
    await expect(page.locator('#context-calls')).toContainText('tool-call:question-call:')
    await expect(page.locator('#window-ids')).toContainText('stored-21')
    await expect(page.locator('#window-ids')).not.toContainText('stored-100')
    const question = page.locator('.hapi-message-pending-target')
    await expect(question).toBeVisible()
    await expect(question).toBeInViewport()
    await expect(question).toContainText('Which historical approach?')
    // Reopen the mixed selector and target the other request, not the first card.
    await page.getByRole('button', { name: '2 pending requests' }).click()
    await page.getByRole('button', { name: 'permission required git status --short' }).click()
    await expect(page.locator('#window-ids')).toContainText('stored-41')
    await expect(page.locator('.hapi-message-pending-target')).toContainText('git status --short')
    await expect(page.locator('.hapi-message-pending-target')).toBeInViewport()
})

test('a late historical context response cannot replace the newer request selection', async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem('hapi-lang', 'en'))
    await page.goto('/e2e-fixtures/pending-context-fixture.html?holdQuestion=1')
    await expect(page.locator('#window-ids')).toContainText('stored-100')
    await page.getByRole('button', { name: '2 pending requests' }).click()
    await page.getByRole('button', { name: 'Needs reply Which historical approach?' }).click()
    await page.waitForFunction(() => (window as Window & { __pendingContextCalls: string[] }).__pendingContextCalls.some(id => id.includes('question')))
    await page.getByRole('button', { name: '2 pending requests' }).click()
    await page.getByRole('button', { name: 'permission required git status --short' }).click()
    await expect(page.locator('#window-ids')).toContainText('stored-41')
    await page.evaluate(() => (window as Window & { __releasePendingQuestion: () => void }).__releasePendingQuestion())
    await expect(page.locator('.hapi-message-pending-target')).toContainText('git status --short')
    await expect(page.locator('.hapi-message-pending-target')).toBeInViewport()
    await page.waitForFunction(() => (window as Window & { __pendingContextCompleted: string[] }).__pendingContextCompleted.some(id => id.includes('question')))
    await expect(page.locator('#window-ids')).toContainText('stored-41')
    await expect(page.locator('#window-ids')).not.toContainText('stored-21')
})
