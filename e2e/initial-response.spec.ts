import { expect, test } from '@playwright/test'
test('immediate feedback hands its place to first output', async ({ page }) => {
    await page.goto('/e2e-fixtures/initial-response-fixture.html')
    const status = page.getByTestId('chat-response-feedback')
    await expect(status).toHaveCount(0)
    await page.getByRole('button', { name: 'sending', exact: true }).click()
    await expect(status).toHaveText('Sending…')
    await expect(status.locator('svg')).toBeVisible()
    await page.getByRole('button', { name: 'waiting', exact: true }).click()
    await expect(status).toHaveText('Waiting to start…')
    await page.getByRole('button', { name: 'thinking', exact: true }).click()
    await expect(status).toHaveText('Thinking…')
    const y = (await status.boundingBox())!.y
    await page.getByRole('button', { name: 'output', exact: true }).click()
    await expect(status).toHaveCount(0)
    const reply = page.getByText('First reply arrives here.', { exact: true })
    await expect(reply).toBeVisible()
    expect(Math.abs((await page.getByTestId('execution-timing').boundingBox())!.y - y)).toBeLessThan(8)
})
test('failed, stopped and switched sessions do not retain a spinner', async ({ page }) => {
    await page.goto('/e2e-fixtures/initial-response-fixture.html')
    const status = page.getByTestId('chat-response-feedback')
    for (const end of ['failed', 'stopped', 'Switch session']) {
        await page.getByRole('button', { name: 'sending', exact: true }).click()
        await expect(status).toBeVisible()
        await page.getByRole('button', { name: end, exact: true }).click()
        await expect(status).toHaveCount(0)
    }
})
