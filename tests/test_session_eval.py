"""Evidence fidelity and false-attribution regressions; all transcripts synthetic."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import session_evidence as evidence
import session_eval as evaluation


def message(role, text, **extra):
    return {"type": "response_item", "timestamp": "2026-01-01T00:00:00Z", "payload": {
        "type": "message", "role": role, "content": [{"type": "input_text", "text": text}], **extra}}


def event(role, text):
    return {"type": "event_msg", "timestamp": "2026-01-01T00:00:00Z", "payload": {
        "type": "user_message" if role == "user" else "agent_message", "message": text}}


class SessionEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "session.jsonl"

    def write(self, *rows):
        self.source.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        return self.source

    def packet(self):
        return evaluation.prepare(self.write(message("user", "Check the change."),
                                             message("assistant", "I cannot verify execution.")))

    def review(self, packet):
        review = evaluation.review_template(packet)
        review["reviewer"] = {"identity": "test reviewer", "kind": "human", "self_review": False}
        review["outcome"]["reason"] = "No result evidence in this packet."
        review["limitations"] = ["One synthetic physical file."]
        review["findings"][0].update(status="uncertain", claim="Framing needs context.",
                                    alternative_explanation="Prior context may suffice.", improvement="Read prior context.",
                                    evidence=[{"event_id": packet["events"][0]["id"],
                                               "quote": packet["events"][0]["text"]}])
        return review

    def test_delegated_brief_and_agent_report_are_not_human_prompts(self):
        self.write({"type": "response_item", "payload": {
            "type": "function_call_output", "name": "create_thread", "output":
            "<codex_delegation><input>Obviously this is right, isn't it?</input></codex_delegation>"}},
            {"type": "response_item", "payload": {"type": "agent_message", "author": "researcher",
             "content": [{"type": "text", "text": "Research report"}]}},
            message("assistant", "Review result", phase="final"))
        packet = evaluation.prepare(self.source)
        self.assertEqual([e["role"] for e in packet["events"]], ["delegated_prompt", "agent_report", "assistant"])
        self.assertEqual(packet["events"][-1]["channel"], "final")
        self.assertTrue(packet["metadata"]["delegated_input"])
        self.assertEqual(packet["signals"], [])

    def test_codex_mirrors_collapse_but_repeat_prompts_survive(self):
        self.write(message("user", "Again"), event("user", "Again"),
                   event("user", "Again"), message("assistant", "Reply"), event("assistant", "Reply"))
        report = evaluation.prepare(self.source)
        self.assertEqual([e["text"] for e in report["events"]], ["Again", "Again", "Reply"])
        self.assertEqual(report["coverage"]["counts"]["duplicates"], 2)
        self.assertEqual([e["line"] for e in report["events"]], [1, 3, 4])

    def test_claude_tools_are_not_user_words_and_thinking_is_excluded(self):
        self.write(
            {"type": "assistant", "uuid": "a", "sessionId": "s", "message": {"model": "model-a", "content": [
                {"type": "thinking", "thinking": "PRIVATE REASONING"},
                {"type": "text", "text": "Checking"},
                {"type": "tool_use", "id": "c", "name": "Bash", "input": {"command": "true"}}]}},
            {"type": "user", "uuid": "b", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "c", "content": "result"}]}},
            {"type": "user", "uuid": "b", "message": {"content": "duplicate"}},
            {"type": "user", "isCompactSummary": True, "message": {"content": "fake user complaint"}},
        )
        packet = evaluation.prepare(self.source)
        self.assertEqual([e["role"] for e in packet["events"]], ["assistant", "tool_call", "tool_result", "context"])
        self.assertNotIn("PRIVATE REASONING", json.dumps(packet))
        self.assertNotIn("fake user complaint", json.dumps(packet))
        self.assertEqual(packet["coverage"]["unmatched_tool_calls"], 0)

    def test_context_and_analysis_not_scored_as_prompts(self):
        self.write(message("user", "# AGENTS.md instructions\n아니 왜 자꾸"),
                   message("assistant", "hidden analysis", channel="analysis"),
                   message("system", "hidden system"), message("user", "맞지?"))
        packet = evaluation.prepare(self.source)
        self.assertEqual([e["role"] for e in packet["events"]], ["context", "user"])
        self.assertNotIn("hidden analysis", json.dumps(packet))
        self.assertEqual(len(packet["signals"]), 1)
        self.assertEqual(packet["signals"][0]["status"], "candidate_only")

    def test_mask_before_clipping_and_report_gaps(self):
        self.write(message("user", "x" * 195 + " sk-" + "A" * 40 + " tail"))
        packet = evaluation.prepare(self.source, excerpt_chars=200)
        self.assertNotIn("sk-", packet["events"][0]["text"])
        self.assertIn("clipped_events", packet["coverage"]["gaps"])

    def test_malformed_and_oversized_lines_preserve_physical_references(self):
        with self.source.open("wb") as handle:
            handle.write(b"not json\n" + b"x" * (evidence.MAX_LINE + 5) + b"\n")
            handle.write(json.dumps(message("user", "visible")).encode() + b"\n")
        packet = evaluation.prepare(self.source)
        self.assertEqual(packet["events"][0]["id"], "L3:0")
        self.assertEqual(packet["coverage"]["counts"]["malformed_lines"], 1)
        self.assertEqual(packet["coverage"]["counts"]["oversized_lines"], 1)
        self.assertIsNotNone(packet["source_sha256"])

    def test_bounded_bytes_withholds_full_source_hash(self):
        self.write(message("user", "large text"))
        packet = evidence.read_evidence(self.source, home=self.root, max_bytes=20)
        self.assertIsNone(packet["source_sha256"])
        self.assertIn("byte_limit", packet["coverage"]["gaps"])

    def test_event_cap_is_explicit(self):
        self.write(message("user", "one"), message("assistant", "two"))
        packet = evaluation.prepare(self.source, max_events=1)
        self.assertEqual(len(packet["events"]), 1)
        self.assertEqual(packet["coverage"]["counts"]["omitted_events"], 1)

    def test_symlink_and_fifo_rejected_without_blocking(self):
        self.write(message("user", "one"))
        link = self.root / "link.jsonl"
        link.symlink_to(self.source)
        with self.assertRaises(OSError):
            evaluation.prepare(link)
        fifo = self.root / "fifo.jsonl"
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            evaluation.prepare(fifo)

    def test_unknown_store_does_not_claim_empty_success(self):
        self.write({"messages": [{"role": "user", "content": "hello"}]})
        packet = evaluation.prepare(self.source)
        self.assertIn("unrecognized_provider", packet["coverage"]["gaps"])

    def test_pending_template_does_not_pass_as_review(self):
        packet = self.packet()
        errors = evaluation.validate_review(packet, evaluation.review_template(packet))
        self.assertTrue(errors)

    def test_exact_quote_and_packet_hash_required(self):
        packet = self.packet()
        review = self.review(packet)
        finding = review["findings"][0]
        finding.update(status="uncertain", claim="Prompt details are sparse.",
                       alternative_explanation="Context may contain criteria.", improvement="Read previous context.",
                       evidence=[{"event_id": "L1:0", "quote": "Check the change."}])
        self.assertEqual(evaluation.validate_review(packet, review), [])
        finding["evidence"][0]["quote"] = "A quote that was never said"
        self.assertTrue(evaluation.validate_review(packet, review))
        packet["events"][0]["text"] = "tampered"
        self.assertIn("packet integrity mismatch", evaluation.validate_review(packet, review))

    def test_assistant_cannot_certify_own_success(self):
        packet = self.packet()
        review = self.review(packet)
        review["outcome"].update(status="observed_success", evidence=[{
            "event_id": "L2:0", "quote": "I cannot verify execution."}])
        self.assertTrue(any("outcome needs" in e for e in evaluation.validate_review(packet, review)))

    def test_interaction_requires_both_actors(self):
        packet = self.packet()
        review = self.review(packet)
        finding = review["findings"][-1]
        finding.update(status="uncertain", claim="Repair is unclear.", alternative_explanation="Missing follow-up.",
                       improvement="Read the next result.", evidence=[{
                           "event_id": "L2:0", "quote": "I cannot verify execution."}])
        self.assertTrue(any("actor(s)" in e for e in evaluation.validate_review(packet, review)))

    def test_duplicate_dimensions_cannot_inflate_summary(self):
        packet = self.packet()
        review = self.review(packet)
        review["findings"].append(copy.deepcopy(review["findings"][0]))
        self.assertTrue(evaluation.validate_review(packet, review))

    def test_private_output_no_overwrite_and_no_git_directory(self):
        out = self.root / "private"
        evaluation.safe_output(out)
        dest = out / "packet.json"
        evaluation.write_private(dest, b"{}")
        self.assertEqual(dest.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            evaluation.write_private(dest, b"new")
        (self.root / ".git").mkdir()
        with self.assertRaises(ValueError):
            evaluation.safe_output(self.root / "tracked")

    def test_summary_reports_unreviewed_and_duplicate_physical_session(self):
        packet = self.packet()
        packet["metadata"]["session_ids"] = ["same-session"]
        packet["packet_sha256"] = evaluation.packet_hash(packet)
        for name in ("a", "b"):
            (self.root / (name + ".packet.json")).write_bytes(evaluation.json_bytes(packet))
        summary = evaluation.summarize([self.root])
        self.assertEqual(summary["unreviewed"], 1)
        self.assertEqual(summary["reviewed"], 0)
        self.assertEqual(summary["duplicate_sessions_excluded"], 1)

    def test_actual_cli_prepare_check_and_summary(self):
        source = self.write(message("user", "Please inspect."), message("assistant", "Evidence is limited."))
        script = Path(evaluation.__file__)
        out = self.root / "artifacts"
        result = subprocess.run([sys.executable, "-I", "-B", str(script), "prepare", str(source), "--out", str(out)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet_path = Path(json.loads(result.stdout)[0]["packet"])
        packet = evaluation.read_json(packet_path)
        review_path = packet_path.with_name(packet_path.name.replace(".packet.json", ".review.json"))
        evaluation.write_private(review_path, evaluation.json_bytes(self.review(packet)))
        checked = subprocess.run([sys.executable, "-I", "-B", str(script), "check", str(packet_path), str(review_path)],
                                 text=True, capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(evaluation.summarize([out])["reviewed"], 1)

    def test_different_judgment_methods_are_not_pooled(self):
        for i, method in enumerate(("session-judge-v1", "session-judge-v2")):
            packet = self.packet()
            packet["metadata"]["session_ids"] = ["different-session-" + str(i)]
            packet["packet_sha256"] = evaluation.packet_hash(packet)
            review = self.review(packet)
            review["method_version"] = method
            (self.root / (str(i) + ".packet.json")).write_bytes(evaluation.json_bytes(packet))
            (self.root / (str(i) + ".review.json")).write_bytes(evaluation.json_bytes(review))
        result = evaluation.summarize([self.root])
        self.assertTrue(result["incompatible_methods"])
        self.assertIsNone(result["dimensions"])

    def test_tool_action_can_evidence_an_instruction_violation(self):
        packet = evaluation.prepare(self.write(message("user", "Do not execute commands."),
            {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command",
             "call_id": "test", "arguments": '{"cmd":"true"}'}}))
        review = self.review(packet)
        finding = next(f for f in review["findings"] if f["dimension"] == "assistant.instruction_miss")
        finding.update(status="supported", claim="A command was invoked despite an explicit prohibition.",
                       attribution="assistant", alternative_explanation="Higher-priority context might be absent.",
                       improvement="Honor the execution prohibition.", evidence=[
                           {"event_id": e["id"], "quote": e["text"]} for e in packet["events"]])
        self.assertEqual(evaluation.validate_review(packet, review), [])


if __name__ == "__main__":
    unittest.main()
