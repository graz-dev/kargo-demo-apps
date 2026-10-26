# Guestbook images for the Kargo workshop

This repo builds the container images that the Kargo GitOps workshop promotes. In the story they are
"what the developers' CI shipped": the workshop never builds them, it only pulls them from GHCR.

One source tree (`app/`) and one catalog (`releases.yaml`) produce every version. There are no
per-version folders.

## Contract with the workshop

- Image `ghcr.io/<owner>/kargo-workshop-guestbook`, SemVer tags **without** a `v` prefix, **immutable**,
  **no `latest`**, `linux/amd64` and `linux/arm64`.
- Listens on port **80**. Reads `STAGE` and `LAMBDA_URL` and renders `/config.js` at start with
  `Cache-Control: no-store`. The page is served with `Cache-Control: no-cache` so a new version shows up on refresh.
- **Verification contract** (the workshop's `AnalysisTemplate`s grep the home page):
  - good versions answer `200` on `/` with `Kargo Guestbook` and `id="entry-form"`;
  - the broken version answers `200` on `/` (so Argo CD stays Healthy) **without** `Kargo Guestbook`, so
    verification fails. *Healthy is not the same as correct*, and the page says so.
- Every version shows its version and a banner message in its own colour.
- OCI labels: `source`, `version`, `revision`, `created`, `title`, `description`.

## Catalog

| Version | Use in the workshop |
|---|---|
| 0.9.0 | What runs today, before Kargo (deployed everywhere by the seed; below the Warehouse constraint `>=1.0.0`) |
| 1.0.0 | Baseline, Lab 1 |
| 1.1.0 | First new release, Lab 2 |
| 1.2.0 | Second new release, Lab 3 |
| 1.3.0 | **Broken** (healthy but not correct), Lab 4 |
| 1.3.1 | The fix, Lab 4 |
| 1.4.0 | Spare for live demos |

`releases.yaml` is the source of truth (`image`, then per version: `version`, `title`, `theme`, `message`,
`broken`, `notes`). Its format is strict and checked by `make validate`.

## Commands

Needs Docker, bash, curl and make. `docker buildx` is needed to publish (`brew install docker-buildx` and link the
plugin into `~/.docker/cli-plugins/`), and `python3` for `teardown`.

```
make list                   # show the catalog
make validate               # check releases.yaml against the rules
make build   [VERSION=1.0.0]  # build local images <image>:<version> (never pushes, never tags latest)
make test    [VERSION=1.0.0]  # build, run and check every version (about 20 s for all seven)
make test-publish           # test publish and teardown against a local registry and a mock GitHub API
make publish  VERSION=1.0.0|all [CONFIRM=yes]
make teardown VERSION=1.0.0|all [CONFIRM=yes]
make lint                   # bash -n, py_compile and shellcheck
```

`make test` runs `tests/contract.sh` against each container: the same greps as the workshop's
AnalysisTemplates (good versions pass, the broken one fails as designed), the `config.js` contract,
the cache headers, the page content and the OCI labels.

## Publishing to GHCR (there is no CI: you publish from your machine)

Credentials are your own `docker login ghcr.io -u <github-user>` (password: a classic token with
`write:packages`). Nothing is stored in this repo.

```
make publish VERSION=1.0.0             # dry run: checks everything and builds for both platforms, pushes nothing
make publish VERSION=1.0.0 CONFIRM=yes   # pushes
make publish VERSION=all   CONFIRM=yes   # pushes the whole catalog
```

Guards, in order: valid catalog · clean working tree with a commit (the `revision` label must point at a
real commit) · logged in to ghcr.io · **none of the tags exists** (tags are immutable: an existing tag is
never overwritten, and `all` refuses if any exists) · builds for `linux/amd64` and `linux/arm64`. After the
push each manifest is checked to hold exactly those two platforms (no provenance or SBOM entries) and its
digest is printed. The owner comes from the `origin` remote, the image name from `releases.yaml`.

**Making the package public is a manual step** (the API cannot do it): after the first publish open
`https://github.com/users/<owner>/packages/container/<image>/settings` (or `orgs/<owner>` for an
organization) → Danger Zone → Change visibility → Public. Then check the pull from a machine that is not
logged in.

## Starting over: teardown

`make teardown VERSION=1.0.0|all [CONFIRM=yes]` deletes published versions so the workshop can be redone
from scratch. It lists what it would delete and does nothing without `CONFIRM=yes`. A version means its tag,
the multi-arch index and the per-platform manifests behind it (GHCR lists each as a package version);
`all` removes every version. The script never deletes the package itself, but GitHub may remove a package once its last version is gone: check that it is still public before the next publish. It uses the GitHub Packages REST API and
needs a classic token with `read:packages` and `delete:packages`: `GITHUB_TOKEN` if set, otherwise the token saved by your `docker login ghcr.io` (so give that token the `delete:packages` scope too); a public version with more
than 5,000 downloads cannot be deleted through the API.

Both scripts are tested without touching GHCR by `make test-publish` (a throwaway registry on
`localhost:5055` and a mock of the API). The tests cover the dry run, the multi-arch manifest, every guard,
pagination over more than 100 versions and the deletion of exactly the right versions.

## Moving the images

The owner and the repository come from the `origin` remote, the image name from `releases.yaml`. If this
repo moves, change `IMAGE_OWNER` in the workshop repo's `workshop.env`.
