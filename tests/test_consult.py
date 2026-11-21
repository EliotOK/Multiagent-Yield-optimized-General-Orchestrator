import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


SCRIPT = (Path(__file__).resolve().parents[1] / "research-multiagent-orchestrator"
          / "scripts" / "consult.py")
spec = importlib.util.spec_from_file_location("mygo_consult", SCRIPT)
consult = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consult)


class ConsultTests(unittest.TestCase):
    def request(self, job, message=None, usage=None, finish="stop"):
        result = {
            "model": consult.PROVIDERS[job["provider"]][2],
            "choices": [{"message": message or {"content": "test response"}, "finish_reason": finish}],
            "usage": usage or {},
        }
        with patch.object(consult, "credential", return_value="mock-key"), patch.object(
            consult, "build_opener"
        ) as build:
            opener = build.return_value
            opener.open.return_value = io.BytesIO(json.dumps(result).encode())
            reply = consult.request_job(job, 20)
            request = opener.open.call_args.args[0]
        return request, reply

    def test_direct_request_uses_the_selected_vendor_and_only_supplied_text(self):
        endpoints = {
            "deepseek": "https://api.deepseek.com/v1/chat/completions",
            "kimi": "https://api.moonshot.cn/v1/chat/completions",
            "glm": "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions",
            "gemini": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        }
        for provider, endpoint in endpoints.items():
            with self.subTest(provider=provider):
                job = {"id": "sample", "provider": provider, "task": "Compare the options", "context": "Approved excerpt"}
                request, reply = self.request(job, {"content": "answer with mock-key"})
                payload = json.loads(request.data)
                self.assertEqual(request.full_url, endpoint)
                self.assertEqual(payload["messages"][-1]["content"], "Compare the options\n\nContext follows:\nApproved excerpt")
                self.assertNotIn("tools", payload)
                self.assertEqual(reply["status"], "ok")
                self.assertEqual(reply["route"], "direct_api")
                self.assertEqual(reply["text"], "answer with [redacted]")

    def test_hosted_fetch_requires_tool_evidence(self):
        job = {"id": "fetch", "provider": "deepseek", "task": "Read a public page", "web": "fetch"}
        request, reply = self.request(job)
        self.assertEqual(json.loads(request.data)["tools"], [{"type": "deepseek_read_url"}])
        self.assertEqual(reply["status"], "web_unverified")

        page = {"url": "https://example.org/research", "title": "Public research"}
        message = {
            "content": "A summary.",
            "annotations": [{"type": "url_citation", "url_citation": page}],
            "server_tool_calls": [{"calls": [{"status": "completed", "page": page}]}],
        }
        _, reply = self.request(job, message, {"server_tool_use": {"tool_fetch": 1}})
        self.assertEqual(reply["status"], "ok")
        self.assertEqual(reply["web_actions"]["opened_pages"], [page])
        self.assertEqual(reply["citations"], [page])

    def test_requires_external_approval_before_running_a_jobs_file(self):
        with patch.object(consult.sys, "argv", ["consult.py", "--jobs", "not-read.json"]), patch.object(
            consult, "read_jobs"
        ) as read, patch.object(consult.sys, "stderr", new_callable=io.StringIO) as stderr:
            with self.assertRaises(SystemExit) as stopped:
                consult.main()
            self.assertEqual(stopped.exception.code, 2)
            self.assertIn("--allow-external", stderr.getvalue())
            read.assert_not_called()

    def test_missing_key_and_upstream_http_error_have_safe_statuses(self):
        job = {"id": "sample", "provider": "glm", "task": "An approved question"}
        with patch.object(consult, "credential", return_value=""), patch.object(consult, "build_opener") as build:
            self.assertEqual(consult.request_job(job, 20)["status"], "missing_credential")
            build.assert_not_called()

        upstream_error = HTTPError("https://example.org", 429, "Rate-limited", {}, io.BytesIO(b"private response"))
        with patch.object(consult, "credential", return_value="mock-key"), patch.object(
            consult, "build_opener"
        ) as build:
            build.return_value.open.side_effect = upstream_error
            reply = consult.request_job(job, 20)
        self.assertEqual(reply["status"], "http_error")
        self.assertEqual(reply["http_status"], 429)
        self.assertNotIn("private response", json.dumps(reply))


if __name__ == "__main__":
    unittest.main()
