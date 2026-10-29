# Build & Scan Pipeline — Post-Mortem & Improvement Plan

This repository contains a GitHub Actions pipeline (`build-scan.yml`) that builds a hardened Docker builder image, compiles a small Java app into a JAR inside it, and scans both images with Trivy. This README documents **what went wrong**, the **post-mortem remediation** (corrective + preventive actions), and **10 things to improve**.

---

## Tools Used

- **GitHub Actions** — CI platform running the `build-scan.yml` workflow (`ubuntu-latest` runners)
- **actions/checkout@v4** — checks out the repository in both jobs
- **Docker** — builds (`docker build`), transfers between jobs (`docker save` / `docker load`), and runs images (`docker run`)
- **eclipse-temurin:21-jdk-alpine** — base image for the hardened builder (`Dockerfile.builder`)
- **apk (Alpine package manager)** — package upgrade tooling referenced in the Dockerfiles
- **javac** (`--release 17`) — compiles `src/main/java/com/example/App.java`
- **jar** (`--create --main-class`) — packages the compiled classes into `app.jar`
- **java** (`java -jar dist/app.jar`) — runs the JAR in the final pipeline step
- **aquasecurity/trivy-action** (pinned to commit `ed142fd…`) — scans `builder-hardened:latest` and `app-jar:latest` images (SARIF and HTML template formats)
- **wget** — downloads the Trivy `html.tpl` report template from raw.githubusercontent.com
- **github/codeql-action/upload-sarif@v3** — uploads Trivy SARIF results to the GitHub Security tab
- **actions/upload-artifact@v4 / actions/download-artifact@v4** — pass the builder image tar and HTML reports between jobs

---

## 1. Ten Things That Went Wrong

1. **Pinned Trivy action commit caused format confusion.** The workflow pins `aquasecurity/trivy-action@ed142fd...`, but during debugging the scan output format was switched from HTML template to SARIF while the step name still says *"Scan with HTML report"* — misleading naming made the failure hard to diagnose.
2. **SARIF uploaded for one image only.** `trivy-builder.sarif` is uploaded to the GitHub Security tab, but the app image (`app-jar`) is scanned to HTML only — its results never reach the Security tab, so vulnerabilities in the final artifact are invisible in the dashboard.
3. **HTML template downloaded but unused.** Both jobs still `wget html.tpl` even after the builder job switched to SARIF — dead network dependency and wasted CI time; if raw.githubusercontent.com hiccups, the job fails for no reason.
4. **Known HIGH CVE left unpatched.** `Dockerfile.app` has `apk upgrade` commented out with a note about `brotli-libs CVE-2026-111497 (HIGH)` — a known vulnerability was knowingly shipped instead of fixed.
5. **`ignore-unfixed: true` masks real risk.** Scans ignore unfixed vulnerabilities, which conveniently hides CVEs (like the brotli one) that have no upstream fix yet but still need tracking/mitigation.
6. **Huge image passed between jobs as a tar artifact.** Job 1 does `docker save` (~hundreds of MB) and uploads it as an artifact; Job 2 downloads and loads it. This is slow, flaky, and burns artifact storage versus building or pushing to a registry.
7. **No registry / no image tagging by commit.** Images are only tagged `latest` locally; nothing is pushed, so builds are unreproducible, untraceable to a commit, and impossible to roll back to.
8. **Pipeline can't fail on vulnerabilities.** No `exit-code` / `severity-gate` is configured, so even CRITICAL findings produce a green build — the scan is purely decorative.
9. **JAR "test" step silently does nothing useful.** The final step runs the container only to copy the JAR out and then invokes `java -jar dist/app.jar` without verifying output/exit behavior — there is no actual smoke test assertion, and `jar --main-class` misuse risk goes unchecked.
10. **Commented-out experiment blocks left in main.** Large swaths of the workflow are commented-out trial-and-error (old HTML scan steps, old upload steps). This signals the pipeline was debugged directly on `main` with no branch/PR review discipline.

---

## 2. Post-Mortem Remediation

### Timeline (reconstructed)
| Phase | What happened |
|---|---|
| Initial setup | Two-stage Docker build created: `Dockerfile.builder` (Temurin 21 JDK alpine) + `Dockerfile.app` (compiles `App.java` into `app.jar`). |
| Scan integration | Trivy action added with an HTML template report; GitHub Security tab upload added later using SARIF. |
| First problem | Trivy SARIF upload requires `format: 'sarif'`; the HTML-template scan produced no uploadable file, so the builder scan was converted to SARIF (commit `dc8a8fe`: *"update Trivy scan report format to SARIF and adjust upload step"*). |
| Second problem | A HIGH CVE (`brotli-libs`) surfaced in the base image. Instead of upgrading packages, `apk upgrade` was commented out and `ignore-unfixed: true` was set — the alert was silenced rather than resolved. |
| Third problem | Cross-job image reuse was implemented via `docker save` + artifacts, making the pipeline slow and fragile. |
| Result | The pipeline goes green, but the app image's vulnerabilities are not gated, not on the Security tab, and the shipped base image carries a known HIGH CVE. |

### Root causes
- **Debugging on the default branch:** experiments (HTML → SARIF, severity filters, ignore flags) were committed straight to `main`, leaving inconsistent state and dead code.
- **Alert fatigue / convenience bias:** security findings were suppressed (`ignore-unfixed`, commented `apk upgrade`) instead of triaged and fixed.
- **No clear ownership of the gate:** nobody defined *which* severities block a build, so scanning became documentation, not enforcement.
- **Missing infrastructure:** no container registry, no artifact signing/tagging strategy, forcing the `docker save` workaround.

### Impact
- Known HIGH vulnerability present in the deliverable image.
- False sense of security: "pipeline passes = we're scanned and safe" is not true.
- Slow, flaky CI (large artifact transfer, external `wget` dependency).
- Inconsistent reporting: SARIF for builder, HTML-only for app.

### What went well
- Multi-job pipeline structure and pinned action SHA show good intent toward reproducibility.
- Trivy is integrated early (builder stage), and reports are retained as artifacts.

### Corrective actions (fix what broke)
| # | Finding addressed | Action | Owner / ETA | Status |
|---|---|---|---|---|
| R1 | Known HIGH CVE shipped (item 4) | Re-enable `apk upgrade --no-cache` in `Dockerfile.app`/`Dockerfile.builder`; rebuild and re-scan to confirm `brotli-libs CVE-2026-111497` is gone or mitigated | DevOps / this sprint | Open |
| R2 | Scans can't fail the build (item 8) | Add a blocking scan with `severity: CRITICAL,HIGH` + `exit-code: 1`; keep full report as non-blocking artifact | DevOps / this sprint | Open |
| R3 | App image invisible on Security tab (item 2) | Emit SARIF from the app-image scan and add `security-analysis-results-upload` for it | DevOps / next PR | Open |
| R4 | Dead `html.tpl` download & stale commented blocks (items 3, 10) | Delete unused `wget`, commented-out steps, and rename misleading step names (item 1) | DevOps / cleanup PR | Open |
| R5 | No smoke-test assertion (item 9) | Add `java -jar dist/app.jar \| grep "Hello from a Java JAR"` with `set -o pipefail` so the job fails on regression | Dev / next PR | Open |

### Preventive actions (stop it recurring)
| # | Root cause | Action | Owner / ETA | Status |
|---|---|---|---|---|
| P1 | Debugging on `main` | Branch protection on `main`: require PR review + green CI before merge | Repo admin / this week | Open |
| P2 | Alert fatigue / suppression | Versioned `.trivyignore` requiring justification, owner, and expiry date per entry; suppressions reviewed in PR | Security lead / this sprint | Open |
| P3 | No gate ownership | Document the severity policy in this README; make gate changes PR-reviewable by security owner | Team / this sprint | Open |
| P4 | Missing registry | Adopt GHCR (`ghcr.io/<repo>/...`) tagged by `github.sha`; remove `docker save` artifact round-trip (item 6, 7) | DevOps / next sprint | Open |
| P5 | Stale bases/actions | Enable Dependabot for Docker base images and GitHub Actions; monthly base-digest refresh | Repo admin / this week | Open |

### Verification / follow-up
- After R1–R3: confirm zero CRITICAL/HIGH findings on both images in the Security tab and a red build when one is introduced (test with a deliberately vulnerable tag).
- After P1: confirm a direct push to `main` is rejected.
- Retro scheduled +2 weeks to review remediation table status; items past ETA escalate at standup.

---

## 3. Ten Things to Improve

1. **Fix the base image CVE properly.** Re-enable `apk upgrade --no-cache` (and pin/update `brotli-libs`) in `Dockerfile.builder`/`Dockerfile.app`; refresh the base digest regularly.
2. **Add a severity gate that fails the build.** Configure Trivy with `severity: CRITICAL,HIGH` and `exit-code: 1` for blocking scans, plus a separate non-blocking full-report scan — and stop relying on `ignore-unfixed` to hide issues.
3. **Push images to a registry with immutable tags** (e.g., `ghcr.io/<repo>/builder:${{ github.sha }}`). Replace the `docker save`/artifact round-trip with `needs:` + registry pull — faster, more reliable, and traceable per commit.
4. **Scan *and* upload SARIF for every image.** Make the app-image scan emit SARIF too and upload both to the Security tab so all findings are centrally tracked (keep HTML only as an optional artifact).
5. **Remove dead code and stale steps.** Delete commented-out scan/upload blocks and the unused `html.tpl` download; if a template report is wanted, fetch it only in the job that uses it (or vendor it into the repo).
6. **Rename steps to match reality.** Steps called "Scan with HTML report" that produce SARIF should be renamed ("Scan image → SARIF") to keep logs and dashboards honest.
7. **Work via branches and PR checks.** Require pull-request review and run the pipeline on PRs (not just pushes to `main`) so experimentation never lands broken on the default branch.
8. **Add a real smoke test with assertions.** After extracting `app.jar`, run it and assert expected output/exit code (e.g., `java -jar dist/app.jar | grep "Hello from a Java JAR"`); fail the job otherwise.
9. **Track accepted risks.** If a CVE must be temporarily ignored, use a versioned `.trivyignore` file with owner, justification, and expiry date — plus Dependabot/Renovate for automated base-image and action bumps.
10. **Harden and slim the runtime path.** Run the app image build with BuildKit caching (`cache-from/to: gha`), drop the `CMD cp` hack in favor of a proper multi-stage copy or Kaniko/buildah, and add `RUN addgroup/adduser` + non-root `USER` for the final image.

---

*Prepared: 2026-10-27 · Repo state at commit `dc8a8fe`*
