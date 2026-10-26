"""Offline tests: no LocalAI, GPU or secrets needed."""
from __future__ import annotations
import importlib.util
import os
from pathlib import Path
import tempfile
import threading
import time
from unittest.mock import patch
import uuid

from fastapi.testclient import TestClient

SOURCE = Path(__file__).resolve().parents[1] / 'gateway' / 'app.py'


def load(tmp):
    os.environ['JOB_ROOT'] = str(tmp)
    os.environ['GETAC_API_KEY'] = 'test-local-key'
    os.environ['GETAC_QUEUE_MAX_PENDING'] = '50'
    spec = importlib.util.spec_from_file_location('queue_test_' + uuid.uuid4().hex, SOURCE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def request(client, key='test-local-key'):
    return client.post('/api/presenter/create', headers={'X-API-Key': key},
        files={'avatar': ('face.png', b'PNG' * 100, 'image/png'),
               'audio': ('speech.wav', b'RIFF' * 100, 'audio/wav')},
        data={'resolution': '480p'})


def wait_until(predicate, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate(): return True
        time.sleep(.02)
    return False


def test_five_requests_fifo_and_auth():
    with tempfile.TemporaryDirectory() as td:
        m = load(Path(td))
        order, active, maximum = [], 0, [0]
        lock = threading.Lock()
        def fake_run(job_id):
            nonlocal active
            with lock:
                active += 1
                maximum[0] = max(maximum[0], active)
                order.append(job_id)
            m._put_status(m.JOB_ROOT / job_id, 'running', 'inference', 25)
            time.sleep(.22)
            m._put_status(m.JOB_ROOT / job_id, 'completed', 'done', 100)
            with lock: active -= 1
        with patch.object(m, '_probe_localai', return_value={'backend_ready': True, 'video_api_ready': True, 'model_installed': True}), patch.object(m, '_run_job', fake_run):
            with TestClient(m.app) as client:
                assert request(client, key='wrong').status_code == 401
                responses = [request(client) for _ in range(5)]
                assert [r.status_code for r in responses] == [202] * 5, [r.text for r in responses]
                ids = [r.json()['job_id'] for r in responses]
                second = client.get('/api/presenter/status/' + ids[2], headers={'X-API-Key': 'test-local-key'}).json()
                assert second['status'] in ('queued', 'running')
                assert 'queue_position' in second and 'jobs_ahead' in second
                assert client.get('/api/presenter/queue', headers={'X-API-Key': 'wrong'}).status_code == 401
                assert wait_until(lambda: all(client.get('/api/presenter/status/' + j, headers={'X-API-Key':'test-local-key'}).json()['status']=='completed' for j in ids))
                assert order == ids, (order, ids)
                assert maximum[0] == 1, maximum


def test_cancel_queued_and_recover():
    with tempfile.TemporaryDirectory() as td:
        m = load(Path(td))
        gate = threading.Event()
        def fake_run(job_id):
            m._put_status(m.JOB_ROOT / job_id, 'running', 'inference', 25)
            gate.wait(timeout=5)
            m._put_status(m.JOB_ROOT / job_id, 'completed', 'done', 100)
        with patch.object(m, '_probe_localai', return_value={'backend_ready': True, 'video_api_ready': True, 'model_installed': True}), patch.object(m, '_run_job', fake_run):
            with TestClient(m.app) as client:
                a,b,c = [request(client).json()['job_id'] for _ in range(3)]
                assert wait_until(lambda: client.get('/api/presenter/status/'+a, headers={'X-API-Key':'test-local-key'}).json()['status']=='running')
                resp = client.post('/api/presenter/cancel/'+b, headers={'X-API-Key':'test-local-key'})
                assert resp.status_code == 200, resp.text
                assert resp.json()['status'] == 'cancelled'
                assert client.get('/api/presenter/status/'+c, headers={'X-API-Key':'test-local-key'}).json()['queue_position'] == 1
                gate.set()
                assert wait_until(lambda: client.get('/api/presenter/status/'+c, headers={'X-API-Key':'test-local-key'}).json()['status']=='completed')
        # Startup recovery of pending (not active) jobs
        new = str(uuid.uuid4())
        folder = m.JOB_ROOT / new
        folder.mkdir()
        (folder / 'speech.wav').write_bytes(b'RIFF')
        (folder / 'portrait.png').write_bytes(b'PNG')
        m._write_json(folder / 'request.json', {'image_filename':'portrait.png','prompt':'hi','resolution':'480p','max_segments':8})
        m._put_status(folder, 'queued', 'waiting', 0)
        m._recover_jobs()
        assert new in m._queue_snapshot()['pending_job_ids']
        m._put_status(folder, 'running', 'running', 25)
        m._recover_jobs()
        assert m._read_status(new)['status'] == 'failed'
        assert new not in m._queue_snapshot()['pending_job_ids']


if __name__ == '__main__':
    test_five_requests_fifo_and_auth()
    test_cancel_queued_and_recover()
    print('ALL QUEUE TESTS PASSED')
