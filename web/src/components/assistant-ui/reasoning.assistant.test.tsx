import { render, cleanup } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { ClientProfileContext } from '@/lib/client-profile'
import { Reasoning, ReasoningGroup } from './reasoning'
afterEach(cleanup)
it('never mounts raw English reasoning or its group header for assistants', () => {
    const { container } = render(<ClientProfileContext.Provider value={{ mode: 'assistant', hideExecutionDetails: true }}>
        <Reasoning type="reasoning" text="The request is to investigate this company" status={{ type: 'running' }} />
        <ReasoningGroup><p>Another internal English preview</p></ReasoningGroup>
    </ClientProfileContext.Provider>)
    expect(container).toBeEmptyDOMElement()
})
