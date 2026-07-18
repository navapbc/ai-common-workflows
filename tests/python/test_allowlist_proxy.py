"""Tests for engine/lib/sandbox/allowlist_proxy.py — host-matching logic.

The end-to-end tunnel behavior (default-deny network, 403 on denied hosts) is
covered by the live sandbox e2e in CI; here we unit-test the allowlist
matcher, which is the security-critical decision surface."""

import importlib.util
import pathlib

_MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "engine" / "lib" / "sandbox" / "allowlist_proxy.py"
)
_spec = importlib.util.spec_from_file_location("allowlist_proxy", _MODULE_PATH)
ap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ap)


def test_exact_host_default_port():
    al = ap.Allowlist("api.anthropic.com")
    assert al.permits("api.anthropic.com", 443)
    assert not al.permits("api.anthropic.com", 80)
    assert not al.permits("evil.com", 443)


def test_case_and_trailing_dot_insensitive():
    al = ap.Allowlist("api.anthropic.com")
    assert al.permits("API.Anthropic.COM", 443)
    assert al.permits("api.anthropic.com.", 443)


def test_subdomain_wildcard_matches_sub_and_bare():
    al = ap.Allowlist("*.amazonaws.com")
    assert al.permits("bedrock-runtime.us-east-1.amazonaws.com", 443)
    assert al.permits("amazonaws.com", 443)
    assert not al.permits("notamazonaws.com", 443)


def test_leading_dot_wildcard():
    al = ap.Allowlist(".googleapis.com")
    assert al.permits("aiplatform.googleapis.com", 443)
    assert al.permits("googleapis.com", 443)


def test_explicit_port_pin():
    al = ap.Allowlist("gateway.internal:8443")
    assert al.permits("gateway.internal", 8443)
    assert not al.permits("gateway.internal", 443)


def test_multiple_entries_comma_and_space():
    al = ap.Allowlist("api.anthropic.com, api.openai.com  sts.amazonaws.com")
    assert al.permits("api.anthropic.com", 443)
    assert al.permits("api.openai.com", 443)
    assert al.permits("sts.amazonaws.com", 443)


def test_no_substring_bypass():
    # A denied host that merely contains an allowed host as a substring must
    # not slip through the exact-match rule.
    al = ap.Allowlist("api.anthropic.com")
    assert not al.permits("api.anthropic.com.evil.com", 443)
    assert not al.permits("evil-api.anthropic.com", 443)


def test_wildcard_no_substring_bypass():
    # ".evil-amazonaws.com" must not match a "*.amazonaws.com" rule.
    al = ap.Allowlist("*.amazonaws.com")
    assert not al.permits("attacker-amazonaws.com", 443)
