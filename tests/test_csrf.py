"""
CSRF cookie: this app's own name, so another tunnel GUI in the same browser cannot break it.

The GUI is opened as http://localhost:<port> through an SSH port-forward. Browsers keep
cookies per host, not per port (RFC 6265, section 8.5). WOOW's GUI on the same host uses
starlette-csrf's default cookie name, csrftoken, signed with its own secret. With one name,
whichever GUI was opened second would answer 403 to every POST and PUT.
"""

from http.cookiejar import CookieJar

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route
from starlette_csrf import CSRFMiddleware


def _other_gui() -> Starlette:
    """A GUI with starlette-csrf's defaults (cookie csrftoken) and a secret of its own."""

    async def ok(request):
        return JSONResponse({"ok": True})

    other = Starlette(routes=[Route("/api/health", ok), Route("/api/tunnel/stop", ok, methods=["POST"])])
    other.add_middleware(CSRFMiddleware, secret="another-gui-secret")
    return other


@pytest.mark.asyncio
async def test_the_csrf_cookie_has_this_apps_own_name(client):
    from backend.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://testserver") as fresh:
        resp = await fresh.get("/api/health")
    assert [h.split("=", 1)[0] for h in resp.headers.get_list("set-cookie")] == ["apporo_csrftoken"]


@pytest.mark.asyncio
async def test_two_guis_in_one_browser_both_keep_working(client, mock_pm):
    from backend.main import app

    jar = CookieJar()  # one jar for both clients, as in a browser: one host, two ports
    async with AsyncClient(transport=ASGITransport(app=_other_gui()), base_url="http://localhost:18000",
                           cookies=jar) as other, \
            AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost:18100",
                        cookies=jar) as ours:
        await other.get("/api/health")  # the other GUI was opened first
        await ours.get("/api/health")
        assert sorted(c.name for c in jar) == ["apporo_csrftoken", "csrftoken"]
        mine = next(c.value for c in jar if c.name == "apporo_csrftoken")
        theirs = next(c.value for c in jar if c.name == "csrftoken")

        # both cookies travel with every request; each app reads its own
        assert (await ours.post("/api/tunnel/stop", headers={"x-csrftoken": mine})).status_code == 200
        assert (await other.post("/api/tunnel/stop", headers={"x-csrftoken": theirs})).status_code == 200
        # and the other GUI's token is not accepted here
        assert (await ours.post("/api/tunnel/stop", headers={"x-csrftoken": theirs})).status_code == 403
    mock_pm.stop.assert_awaited_once()
