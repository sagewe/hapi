import Foundation
import HapiClient
import HapiProtocol
import Testing

struct AskQuestionTests {
    @Test func freeTextDefaultsToAllowedAndOnlyExplicitFalseDisablesIt() throws {
        for dialect in [false, true] {
            for flag in ["", ",\"allowFreeText\":true", ",\"allowFreeText\":false", ",\"allowFreeText\":null", ",\"allowFreeText\":\"false\""] {
                let text = "{\"questions\":[{\"question\":\"Choose\",\"options\":[{\"label\":\"One\"}]\(flag)}]}"
                let input = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                let question = try #require(parseAskUserQuestions(input, cursorDialect: dialect).first)
                #expect(question.allowFreeText == (flag != ",\"allowFreeText\":false"))
                #expect(question.options.map(\.label) == ["One"])
            }
        }
    }

    @Test func textOnlyQuestionsKeepTheirActualInputChannel() throws {
        let input: JSONValue = ["questions": [["question": "Explain?", "options": [], "allowFreeText": true]]]
        let question = try #require(parseAskUserQuestions(input, cursorDialect: false).first)
        #expect(question.options.isEmpty)
        #expect(question.allowFreeText)
    }
}
