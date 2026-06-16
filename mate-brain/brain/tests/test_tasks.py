"""Görev (task) testleri: DB CRUD + REST (TestClient).

Run: .venv/bin/python -m brain.tests.test_tasks
"""

import asyncio
import os


async def test_db() -> int:
    from brain.db import Database

    path = "/tmp/brain-tasks-test.db"
    if os.path.exists(path):
        os.remove(path)
    db = Database(path)
    await db.connect()
    n = 0

    t1 = await db.create_task("akşam Ali'yi ara", user_id=1)
    await db.create_task("çöpü çıkar", user_id=1)
    await db.create_task("toplantı notu", user_id=2)
    assert t1["status"] == "pending" and t1["id"]; n += 1

    # kullanıcıya göre filtre
    u1 = await db.list_tasks(user_id=1)
    u2 = await db.list_tasks(user_id=2)
    assert len(u1) == 2 and len(u2) == 1, (len(u1), len(u2)); n += 1

    # tamamla → pending listesinden düşer
    assert await db.complete_task(t1["id"]) is True; n += 1
    assert await db.complete_task(t1["id"]) is False  # ikinci kez no-op; n sayma
    pending = await db.list_tasks(user_id=1, status="pending")
    done = await db.list_tasks(user_id=1, status="done")
    assert len(pending) == 1 and len(done) == 1, (len(pending), len(done)); n += 1
    assert done[0]["done_at"] is not None; n += 1

    # sil
    await db.delete_task(t1["id"])
    assert len(await db.list_tasks(user_id=1)) == 1; n += 1

    await db.close()
    return n


def test_rest() -> int:
    """REST smoke (TestClient + admin token). LLM_BACKEND vllm (pi spawn yok)."""
    os.environ.setdefault("BRAIN_ADMIN_TOKEN", "test-token")
    os.environ["BRAIN_DB_PATH"] = "/tmp/brain-tasks-rest.db"
    if os.path.exists("/tmp/brain-tasks-rest.db"):
        os.remove("/tmp/brain-tasks-rest.db")
    from fastapi.testclient import TestClient

    from brain.main import app

    H = {"Authorization": "Bearer test-token"}
    n = 0
    with TestClient(app) as c:
        r = c.post("/api/tasks", json={"text": "perdeyi kapat", "user_id": 1}, headers=H)
        assert r.status_code == 200, r.text
        tid = r.json()["id"]; n += 1
        r = c.get("/api/tasks?user_id=1", headers=H)
        assert r.status_code == 200 and len(r.json()) == 1, r.text; n += 1
        r = c.post(f"/api/tasks/{tid}/complete", headers=H)
        assert r.status_code == 200 and r.json()["ok"] is True, r.text; n += 1
        assert len(c.get("/api/tasks?status=pending", headers=H).json()) == 0; n += 1
        # auth yok → 401
        assert c.get("/api/tasks").status_code == 401; n += 1
    return n


async def run() -> None:
    total = await test_db()
    total += test_rest()
    print(f"test_tasks: {total} assertion OK")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
