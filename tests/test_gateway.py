"""Unit checks that do not require Docker, model weights, or GPU."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

SPEC = importlib.util.spec_from_file_location("getac_gateway_app", Path(__file__).parents[1] / "gateway" / "app.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.original_root = mod.JOB_ROOT
        self.original_key = mod.API_KEY
        mod.JOB_ROOT = Path(self.temp.name)
        mod.API_KEY = "secret"
        self.client = TestClient(mod.app)

    def tearDown(self):
        mod.JOB_ROOT = self.original_root
        mod.API_KEY = self.original_key
        self.client.close()
        self.temp.cleanup()

    def test_requires_api_key(self):
        r = self.client.post("/api/presenter/create", files={
            "avatar": ("p.png", b"pretend_png", "image/png"),
            "audio": ("a.wav", b"pretend_wav", "audio/wav"),
        })
        self.assertEqual(401, r.status_code)

    def test_create_get_and_missing_result(self):
        def mock_job(folder, *args):
            mod._put_status(folder, "running", "Mock, no GPU", 33)
            mod._job_lock.release()
        with patch.object(mod, "_run_job", side_effect=mock_job):
            r = self.client.post("/api/presenter/create", headers={"X-API-Key": "secret"}, files={
                "avatar": ("p.png", b"pretend_png", "image/png"),
                "audio": ("a.wav", b"pretend_wav", "audio/wav"),
            })
        self.assertEqual(202, r.status_code, r.text)
        job_id = r.json()["job_id"]
        state = self.client.get("/api/presenter/status/" + job_id, headers={"X-API-Key": "secret"})
        self.assertEqual(200, state.status_code)
        self.assertIn(state.json()["status"], ["queued", "running"])
        resp = self.client.get("/api/presenter/result/" + job_id, headers={"X-API-Key": "secret"})
        self.assertEqual(409, resp.status_code)
        self.assertEqual(400, self.client.get("/api/presenter/status/not-a-uuid", headers={"X-API-Key": "secret"}).status_code)

    def test_localai_url_response_parser(self):
        self.assertEqual('/generated-videos/a.mp4', mod._extract_video_url({"data": [{"url": "/generated-videos/a.mp4"}]}))
        self.assertEqual('b64:YQ==', mod._extract_video_url({"data": [{"b64_json": "YQ=="}]}))


if __name__ == '__main__':
    unittest.main()
