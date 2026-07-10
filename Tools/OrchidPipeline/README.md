# Orchid

Orchid moves upstream catalog discovery and collection metadata parsing out of the iOS launch path. It produces static, content-addressed JSON that can be published by GitHub Actions and consumed by the app without embedding GitHub credentials.

## Guarantees

- One HTTP session, cookie jar, region, language, and `firstLaunch` value per run.
- Conditional requests for vector and playlist resources using persisted ETags.
- A hard per-run request budget, a separate vector allocation that preserves playlist capacity, and immediate stop on HTTP 429 with `Retry-After` reporting.
- Rotating vector and playlist batches, with offset checkpoints for long vectors.
- Canonical JSON and SHA-256 content identities.
- Content-addressed playlist and catalog objects.
- Quality gates before the latest manifest is replaced.
- Cached source payload fallback when a previously healthy endpoint is temporarily unavailable.
- No YouTube audio stream URLs, account cookies, or personal listening data in output.

## Local Verification

```sh
ruby Tools/OrchidPipeline/test/orchid_pipeline_test.rb
```

Run a bounded live probe before a full crawl:

```sh
ORCHID_SOURCE_URL="<upstream base URL>" ruby Tools/OrchidPipeline/bin/build_orchid \
  --output .build/orchid/public \
  --state .build/orchid/source-state.json \
  --max-vectors 1 \
  --max-pages 1 \
  --minimum-collections 1
```

Run the same command again to verify `304 Not Modified` reuse for unchanged resources.

## Output

- `manifest.json`: atomic latest-version pointer.
- `objects/<sha256>.json`: immutable catalog and playlist payloads.
- `source-state.json`: private crawler state containing ETags and normalized source payloads. This file must not be served to the app.

The app should cache the last known good manifest and catalog, check the manifest frequently with HTTP caching, and only download content-addressed objects it does not already have.

## GitHub Actions

`.github/workflows/orchid-catalog.yml` runs at 04:16, 10:16, 16:16, and 22:16 in `Asia/Taipei`. It:

1. Tests the builder.
2. Restores source state and immutable objects from the `orchid-data` branch.
3. Refreshes up to four vector sources with at most 24 page requests, then hydrates up to eight playlists within a 40-request total budget.
4. Pushes state only when ETags or normalized content changed.
5. Deploys the public directory only when content changed.

The complete catalog is accumulated across runs. New collection artwork can appear before every playlist is hydrated; a collection receives a `tracks` object only after its playlist payload has passed parsing. The app must keep its direct-source fallback for a collection that has not been hydrated yet.

The first successful run creates `orchid-data`. GitHub Pages deployment is intentionally disabled until the repository variable `ORCHID_PAGES_ENABLED` is set to `true` and Pages is configured to use GitHub Actions. This prevents a new repository from failing before its publication policy is chosen.

The workflow also requires the repository secret `ORCHID_SOURCE_URL`. Keep the upstream hostname out of committed files and logs.

For a private source repository, confirm that the resulting Pages URL is anonymously readable before wiring it into the app. Never put a GitHub token in the iOS bundle. If the Pages URL is private, publish the sanitized `public` directory to a separate public data repository instead.
