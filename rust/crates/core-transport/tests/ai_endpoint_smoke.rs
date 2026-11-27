//! Opt-in real model QA. Without an explicit endpoint this performs no network
//! request. A returned command remains a draft and is never executed.
use core_transport::generate_ai_command;

#[tokio::test]
async fn actual_ai_endpoint_returns_a_prompt_specific_command_when_configured() {
    let endpoint = match std::env::var("TERMPULSE_AI_QA_ENDPOINT") {
        Ok(endpoint) if !endpoint.trim().is_empty() => endpoint,
        _ => {
            eprintln!("SKIP actual AI smoke: set TERMPULSE_AI_QA_ENDPOINT and TERMPULSE_AI_QA_MODEL to opt in.");
            return;
        }
    };
    let model = std::env::var("TERMPULSE_AI_QA_MODEL")
        .expect("TERMPULSE_AI_QA_MODEL is required when opting into the actual AI endpoint test");
    assert!(!model.trim().is_empty(), "AI smoke model must not be blank");
    let key = std::env::var("TERMPULSE_AI_QA_KEY").ok();
    let prompt = "Return a shell command that prints exactly TERMPULSE_AI_SMOKE followed by a newline, using printf. Do not execute it.";
    let draft = generate_ai_command(&endpoint, key.as_deref(), &model, prompt, "Linux", "bash")
        .await
        .expect("Actual model endpoint failed to produce a command draft");
    assert!(
        draft.command.contains("TERMPULSE_AI_SMOKE"),
        "The model did not follow the harmless test prompt: {}",
        draft.command
    );
    assert!(
        draft.command.contains("printf"),
        "The model did not return the requested printf draft"
    );
    assert!(draft.sent_context_preview.contains(prompt));
    eprintln!(
        "Actual AI model smoke passed: model={model}; command draft={}",
        draft.command
    );
}
