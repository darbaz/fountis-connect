# Changelog

## 1.1.0 — 2026-10-19

Version aligned with the other FOUNTIS Connect packages; no changes.

## 1.0.0

First stable release of `fountis_connect_platform_interface`.

- The shared platform interface and the MethodChannel client used by iOS and Android for the `fountis_connect` plugin.
- A token provider that throws is reported to the native SDKs as a failure (new `rejectToken` channel method), not as "signed out", so a signed-in person is never offered guest studies.
