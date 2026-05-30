"""Unit tests for fetch-geoip.py — synthetic GeoLite2 ZIP, no network."""
import importlib.util
import io
import json
import os
import pathlib
import sys
import zipfile

# Load the script (named with a hyphen so plain `import` doesn't work)
_HERE = pathlib.Path(__file__).parent
_spec = importlib.util.spec_from_file_location("fetch_geoip", _HERE / "fetch-geoip.py")
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)


# --- synthetic-ZIP factory ---------------------------------------------------
def _make_zip(tmp_path, locations_rows, v4_rows, v6_rows, date="20260530"):
    """Build a GeoLite2-Country-CSV-shaped zip in tmp_path. Returns path."""
    zip_path = tmp_path / "GeoLite2-Country-CSV.zip"
    prefix = "GeoLite2-Country-CSV_" + date + "/"

    def csv_bytes(header, rows):
        buf = io.StringIO()
        buf.write(",".join(header) + "\n")
        for row in rows:
            buf.write(",".join(row) + "\n")
        return buf.getvalue().encode("utf-8")

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(prefix + "COPYRIGHT.txt", b"(c) MaxMind")
        zf.writestr(
            prefix + "GeoLite2-Country-Locations-en.csv",
            csv_bytes(
                ["geoname_id", "locale_code", "continent_code", "continent_name",
                 "country_iso_code", "country_name", "is_in_european_union"],
                locations_rows,
            ),
        )
        zf.writestr(
            prefix + "GeoLite2-Country-Blocks-IPv4.csv",
            csv_bytes(
                ["network", "geoname_id", "registered_country_geoname_id",
                 "represented_country_geoname_id", "is_anonymous_proxy",
                 "is_satellite_provider", "is_anycast"],
                v4_rows,
            ),
        )
        zf.writestr(
            prefix + "GeoLite2-Country-Blocks-IPv6.csv",
            csv_bytes(
                ["network", "geoname_id", "registered_country_geoname_id",
                 "represented_country_geoname_id", "is_anonymous_proxy",
                 "is_satellite_provider", "is_anycast"],
                v6_rows,
            ),
        )
    return zip_path


def test_filter_picks_only_wanted_country(tmp_path):
    """Rows whose geoname_id maps to a country we didn't ask for are dropped."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[
            ["6252001", "en", "NA", "North America", "US", "United States", "0"],
            ["6251999", "en", "NA", "North America", "CA", "Canada", "0"],
        ],
        v4_rows=[
            ["1.0.0.0/24", "6252001", "6252001", "", "0", "0", "0"],   # US
            ["2.0.0.0/24", "6251999", "6251999", "", "0", "0", "0"],   # CA
            ["3.0.0.0/24", "6252001", "6252001", "", "0", "0", "0"],   # US
        ],
        v6_rows=[],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    out = json.loads((tmp_path / "geoip-us-v4.json").read_text())
    assert out["country"] == "US"
    assert out["ip_version"] == "v4"
    assert "2.0.0.0/24" not in out["cidrs"]   # CA excluded
    assert "1.0.0.0/24" in out["cidrs"]
    assert "3.0.0.0/24" in out["cidrs"]


def test_coalesce_adjacent_prefixes(tmp_path):
    """Two adjacent /24s should collapse to one /23."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[["1", "en", "NA", "NA", "US", "United States", "0"]],
        v4_rows=[
            ["10.0.0.0/24", "1", "1", "", "0", "0", "0"],
            ["10.0.1.0/24", "1", "1", "", "0", "0", "0"],
        ],
        v6_rows=[],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    out = json.loads((tmp_path / "geoip-us-v4.json").read_text())
    assert out["cidrs"] == ["10.0.0.0/23"], "adjacent /24s must collapse: " + str(out["cidrs"])


def test_falls_back_to_registered_country_when_geoname_blank(tmp_path):
    """Some satellite/anonymous blocks have a blank `geoname_id` but populated
    `registered_country_geoname_id`. Helper must use the fallback."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[["1", "en", "NA", "NA", "US", "United States", "0"]],
        v4_rows=[
            ["5.0.0.0/24", "", "1", "", "1", "0", "0"],     # anonymous proxy, registered US
            ["6.0.0.0/24", "", "", "", "0", "0", "0"],      # both blank — must be SKIPPED
        ],
        v6_rows=[],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    out = json.loads((tmp_path / "geoip-us-v4.json").read_text())
    assert "5.0.0.0/24" in out["cidrs"], "registered-country fallback should pick this up"
    assert "6.0.0.0/24" not in out["cidrs"], "row with no country info must be skipped"


def test_v6_separate_file(tmp_path):
    """v4 and v6 land in different files; same shape."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[["1", "en", "NA", "NA", "US", "United States", "0"]],
        v4_rows=[["1.0.0.0/24", "1", "1", "", "0", "0", "0"]],
        v6_rows=[["2001:db8::/32", "1", "1", "", "0", "0", "0"]],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    v4 = json.loads((tmp_path / "geoip-us-v4.json").read_text())
    v6 = json.loads((tmp_path / "geoip-us-v6.json").read_text())
    assert v4["cidrs"] == ["1.0.0.0/24"]
    assert v6["cidrs"] == ["2001:db8::/32"]
    assert v4["ip_version"] == "v4"
    assert v6["ip_version"] == "v6"


def test_atomic_write_no_partial_file(tmp_path):
    """write_json must use tempfile+rename so a concurrent reader can't see
    a half-written file. We can't easily test the rename itself, but we
    CAN assert no .tmp leftover after a successful run."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[["1", "en", "NA", "NA", "US", "United States", "0"]],
        v4_rows=[["1.0.0.0/24", "1", "1", "", "0", "0", "0"]],
        v6_rows=[],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    leftover = [f for f in os.listdir(tmp_path) if f.endswith(".tmp")]
    assert not leftover, "left a .tmp file behind: " + str(leftover)


def test_malformed_cidr_row_is_skipped_not_fatal(tmp_path):
    """One bad row in MaxMind's CSV must not 502 the whole timer."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[["1", "en", "NA", "NA", "US", "United States", "0"]],
        v4_rows=[
            ["1.0.0.0/24", "1", "1", "", "0", "0", "0"],
            ["not-a-cidr", "1", "1", "", "0", "0", "0"],   # malformed
            ["3.0.0.0/24", "1", "1", "", "0", "0", "0"],
        ],
        v6_rows=[],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    out = json.loads((tmp_path / "geoip-us-v4.json").read_text())
    assert "1.0.0.0/24" in out["cidrs"]
    assert "3.0.0.0/24" in out["cidrs"]


def test_sorted_output_for_stable_diffs(tmp_path):
    """Output ordering must be deterministic across runs so git diffs only
    show real-world prefix changes, not reshuffling."""
    zip_path = _make_zip(
        tmp_path,
        locations_rows=[["1", "en", "NA", "NA", "US", "United States", "0"]],
        # Reverse alphabetical input; coalesced output should still sort.
        v4_rows=[
            ["9.0.0.0/24", "1", "1", "", "0", "0", "0"],
            ["1.0.0.0/24", "1", "1", "", "0", "0", "0"],
            ["5.0.0.0/24", "1", "1", "", "0", "0", "0"],
        ],
        v6_rows=[],
    )
    m.main([
        "--countries", "US",
        "--output-dir", str(tmp_path),
        "--zip-path", str(zip_path),
    ])
    out = json.loads((tmp_path / "geoip-us-v4.json").read_text())
    assert out["cidrs"] == ["1.0.0.0/24", "5.0.0.0/24", "9.0.0.0/24"]


def test_missing_country_arg_fails():
    try:
        m.main(["--output-dir", "/tmp"])
    except SystemExit:
        pass  # argparse exits non-zero for missing required arg
    else:
        assert False, "should have exited on missing --countries"


def test_no_license_key_no_zip_path_fails(tmp_path, monkeypatch):
    monkeypatch.delenv("MAXMIND_LICENSE_KEY", raising=False)
    try:
        m.main(["--countries", "US", "--output-dir", str(tmp_path)])
    except SystemExit as e:
        assert "license key" in str(e).lower() or "MAXMIND" in str(e)
    else:
        assert False, "should have exited on no creds + no --zip-path"
