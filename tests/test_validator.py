"""
Test 4: Validator security tests
Covers: the container image allow-list, token format validation, and injection protection
"""

import pytest

from backend.services.validator import validate_image, validate_tunnel_token


# =========================================================================
# Image allow-list
# =========================================================================
class TestValidateImage:
    """Only the official cloudflare/cloudflared image is allowed."""

    @pytest.mark.parametrize(
        "image",
        [
            "cloudflare/cloudflared:latest",
            "docker.io/cloudflare/cloudflared:latest",
            "cloudflare/cloudflared:2024.1.0",
            "cloudflare/cloudflared:2024.12.1",
            "docker.io/cloudflare/cloudflared:2024.1.0-rc1",
        ],
    )
    def test_valid_images(self, image):
        assert validate_image(image) is True

    @pytest.mark.parametrize(
        "image,reason",
        [
            ("nginx:latest", "not a cloudflared image"),
            ("cloudflare/cloudflared", "missing tag"),
            ("evil/cloudflared:latest", "spoofed namespace"),
            ("cloudflare/cloudflared:latest; rm -rf /", "injection attempt"),
            ("docker.io/evil/cloudflared:latest", "spoofed namespace with registry"),
            ("ghcr.io/cloudflare/cloudflared:latest", "not the docker.io registry"),
            ("", "empty string"),
            ("cloudflare/cloudflared:", "empty tag"),
        ],
    )
    def test_invalid_images(self, image, reason):
        assert validate_image(image) is False, f"should be rejected: {reason}"


# =========================================================================
# Tunnel token validation
# =========================================================================
class TestValidateTunnelToken:
    """A token has at least 10 characters and no shell metacharacters."""

    def test_valid_jwt_token(self):
        # A typical eyJ... base64 JWT-style token
        token = "eyJhIjoiMTIzIiwidCI6IjQ1NiIsInMiOiI3ODkifQ=="
        assert validate_tunnel_token(token) is True

    def test_valid_api_token(self):
        token = "VbABwopRd9lHzUvwCsuFos6eb4bhUKXmcCadtYpr"
        assert validate_tunnel_token(token) is True

    def test_token_too_short(self):
        assert validate_tunnel_token("abc") is False
        assert validate_tunnel_token("123456789") is False  # 9 chars

    def test_token_exactly_10_chars(self):
        assert validate_tunnel_token("1234567890") is True

    def test_empty_token(self):
        assert validate_tunnel_token("") is False

    def test_none_like_empty(self):
        # None is not a str, but validate_tunnel_token checks for a falsy value first
        assert validate_tunnel_token("") is False

    @pytest.mark.parametrize(
        "bad_token",
        [
            "token;inject",
            "token&inject",
            "token|inject",
            "token`inject`",
            "token$(inject)",
            "token(){inject}",
        ],
    )
    def test_shell_injection_rejected(self, bad_token):
        assert validate_tunnel_token(bad_token) is False
