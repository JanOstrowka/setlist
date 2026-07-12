"""Guards for the hosted site (site/): shared-asset sync + structural invariants.

The hosted site reuses web/app.js and web/styles.css verbatim (copied by
scripts/build_site.py and committed, so Vercel deploys plain static files).
These tests fail the suite when the copies drift or the site page loses one of
the elements/hooks the shared script depends on.
"""
from pathlib import Path

from app.config import APP_NAME

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
WEB = ROOT / "web"


def test_shared_assets_in_sync():
    for name in ("app.js", "styles.css"):
        assert (SITE / name).read_bytes() == (WEB / name).read_bytes(), (
            f"site/{name} differs from web/{name} — run scripts/build_site.py"
        )


def test_site_index_loads_site_glue_before_shared_app():
    html = (SITE / "index.html").read_text(encoding="utf-8")
    assert html.index("site.js") < html.index("app.js"), (
        "site.js must load before app.js so the deployment seams exist at click time"
    )


def test_site_index_has_all_elements_the_shared_script_uses():
    """Every DOM id app.js touches must exist in the site page too."""
    import re

    app_js = (WEB / "app.js").read_text(encoding="utf-8")
    html = (SITE / "index.html").read_text(encoding="utf-8")
    ids_used = set(re.findall(r'\$\("([A-Za-z0-9_]+)"\)', app_js))
    ids_present = set(re.findall(r'id="([A-Za-z0-9_]+)"', html))
    missing = ids_used - ids_present
    assert not missing, f"site/index.html is missing ids used by app.js: {sorted(missing)}"


def test_site_index_carries_the_brand():
    html = (SITE / "index.html").read_text(encoding="utf-8")
    assert f"<title>{APP_NAME}</title>" in html


def test_site_ships_no_personal_config():
    """The static site must stay generic: no baked-in n8n instance or tokens.

    (The public GitHub repo URL in the setup instructions is fine — it's the
    product's home, not configuration.)
    """
    for name in ("index.html", "site.js", "site.css"):
        text = (SITE / name).read_text(encoding="utf-8")
        assert "janostrowka.app.n8n.cloud" not in text.lower(), (
            f"personal n8n instance leaked into site/{name}"
        )
