# Notes to Developers — Getting Your Application Repo Ready for k8secops-gate

This document is for **application developers** onboarding a repository onto k8secops-gate — not for engineers working on the platform's own codebase (see [docs/DEVELOPER_HANDOVER.md](DEVELOPER_HANDOVER.md) for that, and [docs/TESTING.md](TESTING.md) for how the platform tests *itself*). If you're the person who owns a Java/Python/Node/Go/.NET/Rust/TypeScript/C++/Terraform repo and you've just been told "we're putting this through k8secops-gate," this is the doc that tells you exactly what the pipeline expects from your repo, and — since it's the thing most likely to quietly go wrong — how to write unit tests that the platform will actually pick up and report on correctly.

Every claim in this document is checked directly against the current pipeline task definitions (`platform/tekton/tasks/build/compile-*.yaml`, `platform/tekton/tasks/tests/test-*.yaml`, and their per-build-tool scripts under `platform/tekton/tasks/build/scripts/<language>/` and `platform/tekton/tasks/tests/scripts/<language>/`) as of 2026-08-03, not against a design intent that may have drifted from what's actually deployed.

---

## Table of Contents

1. [How the platform sees your repo](#how-the-platform-sees-your-repo)
2. [The one philosophy you need to internalize: nothing here blocks your pipeline](#the-one-philosophy-you-need-to-internalize)
3. [Java](#java)
4. [.NET](#net)
5. [Python](#python)
6. [Node.js](#nodejs)
7. [React](#react)
8. [Next.js](#nextjs)
9. [Go](#go)
10. [Rust](#rust)
11. [TypeScript](#typescript)
12. [C/C++](#cc)
13. [Terraform](#terraform)
14. [Extra credentials cheat sheet](#extra-credentials-cheat-sheet)
15. [Troubleshooting checklist](#troubleshooting-checklist)

---

## How the platform sees your repo

When your app is onboarded, five pieces of information about your repo get recorded on a `GitOpsPipeline` Custom Resource: **language**, **build tool**, **build file path**, **build context** (for monorepos), and a handful of **test-related fields** specific to your language (test directory, test project file, test script name, etc. — see your language's section below). Everything else — which of the 15 security/quality scanners run, the Tekton DAG shape, the container image build — is derived from that plus your per-app scanner configuration.

A few things worth knowing up front, because they change how forgiving the platform is about repo layout:

- **`ai-preflight` is a safety net for three specific fields — `build-file`, `dockerfile-path`, and `test-dir` — but explicitly *not* for `build-context`.** Immediately after clone, a preflight step scans your repo for the real build manifest, Dockerfile, and conventional test directory. For those three fields, if your configured value doesn't exist on disk: with **exactly one** real candidate found, it auto-corrects to that candidate deterministically (no AI call involved). With **multiple** candidates, it calls the AI provider configured for your app (if any) to pick one — constrained to literally choosing a path it saw in the candidate list, never inventing one — and falls back to just flagging the ambiguity in the run's AI report if no AI is configured or the call fails. With **zero** candidates, it flags that too and passes your original value straight through.
  **`build-context` gets none of this.** It's only checked for being a real directory in your repo — if it isn't, preflight leaves it completely unchanged and notes that Kaniko will fail if it's genuinely wrong. There is no single-candidate auto-fix and no AI disambiguation for `build-context`, ever, regardless of how unambiguous the right answer might look to a human. **If you're hitting recurring path errors, `build-context` is the single most likely field to double-check by hand** — it's the one place ai-preflight cannot bail you out.
- **Monorepos are supported** via `image.buildContext` (Docker build context) and `image.dockerfilePath` (both relative to repo root) plus each language's own build-file path — set these to your service's subdirectory, e.g. `buildContext: services/api`, `dockerfilePath: services/api/Dockerfile`.
- **A `precompileScript` hook exists** for build needs the standard pipeline can't anticipate — e.g. pulling private artifacts from object storage before compile starts. It's a script path (relative to build-context) that runs once before your language's compile stage, in a configurable image (defaults to a lightweight Python+pip image), and installs its own tooling. A failure here blocks compile — this is the one stage in the whole test/build pipeline that's allowed to hard-fail, because it usually means "the build literally cannot proceed without this."
- **Repo credentials never end up in plaintext CI logs or PipelineRun manifests.** If your build needs a private package registry, a test-time database, or any other credential, see the [extra credentials cheat sheet](#extra-credentials-cheat-sheet) — don't hardcode anything into your Dockerfile or CI config.

---

## The one philosophy you need to internalize

**No unit test result — passing, failing, or missing — ever stops your pipeline from reaching the human gate.** This is deliberate, not an oversight: a developer or reviewer decides at the gate what to do with an image that has failing tests or low coverage, not an automated stage earlier in the pipeline. Every language's `check-and-notify` step explicitly never fails the Tekton task on test outcome — it only posts the results to the operator so they're visible at the gate.

This means **"the pipeline went green" is not the same signal as "tests passed."** If you're used to a CI system where a red test suite blocks the merge, recalibrate: here, a red test suite still reaches a human, with the failure visible and labeled, and that human makes the call. Don't rely on pipeline-goes-green as your test-passing signal — check the run's test/coverage panel directly.

The second thing worth understanding: every language's test task reports a `TESTS_EXECUTED` flag (`true`/`false`) alongside pass/fail counts and coverage. This exists specifically to distinguish **"zero tests, and that's a genuinely clean result"** from **"the test runner itself never produced a report at all"** (broken dependency install, wrong test command, missing test binary, etc.). If your test stage shows 0 passed / 0 failed, check `TESTS_EXECUTED` before assuming your test suite is just empty — a `false` there means something upstream of your actual tests broke, and the logs for the `test`/`run-tests` step (not `parse-results`) are where to look.

Coverage threshold defaults to **80%** and is configurable per app (`tests.coverageThreshold` in the onboarding wizard / CRD). Like test pass/fail, it's advisory at the gate, not a hard block.

---

## Java

**Onboarding fields:** build tool (`maven` / `gradle` / `ant`), build file path (`pom.xml` / `build.gradle` / `build.xml`), JDK version (`17` or `21`), coverage threshold. Optional: **test module** — only needed for multi-module builds where tests live in a module other than the root.

**Build tools supported:** Maven, Gradle, and Ant, each with its own dedicated script (`platform/tekton/tasks/tests/scripts/java/test-maven.sh`, `test-gradle.sh`, `test-ant.sh`). If your project ships a Maven Wrapper (`./mvnw`) or Gradle Wrapper (`./gradlew`), the pipeline prefers it over a system-installed Maven/Gradle — this matters if your project is pinned to a specific tool version, since compile and test would otherwise silently use different tool versions.

**How tests run and are reported:**
- Maven: `mvn test` (or `mvnw test` if present) followed by `mvn jacoco:report`. Reuses the exact same local repository cache (`~/.m2`) that the compile stage already populated moments earlier in the same run — cold-cache Maven Central resolution only happens once per run, not once per stage.
- Gradle: `./gradlew build test jacocoTestReport` (or a module-scoped variant if `testModule` is set).
- Ant: `ant test` — Ant has no standardized build lifecycle, so `test` is used as the near-universal convention for the JUnit-ant-task target name. **If your `build.xml` doesn't define a `test` target, this stage will report zero tests and `TESTS_EXECUTED=false` — not a platform bug, an Ant convention you need to follow.**
- Test results are collected from any `TEST-*.xml` files (standard Surefire/Gradle/Ant JUnit XML report format) anywhere under the project after the test run. Coverage is read from `jacoco.xml` — **your project needs the JaCoCo plugin configured** (Maven: `jacoco-maven-plugin`; Gradle: the `jacoco` plugin) for coverage to be collected at all. Without it, tests still run and report pass/fail correctly, but coverage reads as 0%.

**Multi-module projects:** set `testModule` to the module containing your tests (e.g. `app-tests`) — this scopes both `mvn test -pl <module>` / `mvn jacoco:report -pl <module>` and `gradlew :<module>:test :<module>:jacocoTestReport` to that module specifically. Leave it blank for a standard single-module `src/test` layout.

**Packaging: JAR, WAR, or EAR are all supported** — a Jakarta/Java EE webapp (WebSphere Liberty, Open Liberty, Tomcat, ...) packages as a WAR, not a runnable JAR, and `mvn package`/`gradlew assemble` already produce whichever your `pom.xml`/`build.gradle` declares. Your Dockerfile just needs to `COPY` the right artifact for your runtime -- e.g. for Open Liberty, `COPY target/*.war /config/apps/` plus your own `server.xml`, then `RUN configure.sh` (see the `liberty-app` sample in the separate `k8secops/testapps` repo — not part of this repository — for a complete working example). The platform's own artifact-verification step checks for a `.jar`/`.war`/`.ear` generically, not a runnable JAR specifically.

**SAST note:** SpotBugs runs as this language's static-analysis tool and needs the project to **compile cleanly first** — a project that doesn't build will show as a SpotBugs failure, not necessarily a SpotBugs configuration problem.

---

## .NET

**Onboarding fields:** `.csproj` file path (application project), .NET version (`6.0` / `8.0` / `9.0`), coverage threshold. **Required:** test project `.csproj` path (`tests.testFile`).

**The one thing that will break your build if you get it wrong:** application code and test code **must be separate projects** in your solution. A single `.csproj` that mixes `Microsoft.NET.Test.Sdk` (test framework references) with `<OutputType>Exe</OutputType>` (an application entry point) breaks `dotnet publish` — the SDK doesn't cleanly support a project being both a runnable app and a test project at once. Structure your repo as at minimum `src/MyApp/MyApp.csproj` (the application, referenced by `image.dockerfilePath`'s build) and `tests/MyApp.Tests/MyApp.Tests.csproj` (the test project, referenced by `tests.testFile`) — two separate `.csproj` files, not one.

**Compile and test treat your configured .NET version differently — this matters.** The **compile** stage always runs on the SDK 9.0 image regardless of what you configured, because SDK 9.0 can restore/build/publish `net6.0`–`net9.0` projects (backward compatible). A separate `detect-version` step inspects your `.csproj`'s actual `TargetFramework` and prints a warning (not a failure) if it's higher than your configured version, telling you to update your app's configured .NET version — but **compile itself will still succeed either way**. The **test** stage is stricter, for a hard technical reason: `dotnet test` needs the version you configured to actually *run* the compiled test binaries, and SDK 9.0 can *cross-compile* a `net8.0` project but cannot *run* `net8.0` binaries (it only ships the .NET 9 runtime). **So: get the configured version right for test correctness, even though a mismatch won't block compile.** If your `.csproj` declares `<TargetFramework>net8.0</TargetFramework>`, configure `8.0`, not `9.0`, even though compile alone would have tolerated the mismatch.

**`build-file` can point at a `.sln` instead of a `.csproj`** — `dotnet restore`/`dotnet build` both accept a solution file directly, but `dotnet publish` doesn't support solution files at all (a documented CLI limitation), so if you configure a `.sln`, compile automatically locates **the single project in it** that looks publishable (`Sdk="Microsoft.NET.Sdk.Web"` or `<OutputType>Exe</OutputType>`) and publishes that one instead. **If your solution contains more than one such candidate project, compile fails outright** with an explicit error telling you to point `build-file` at the specific `.csproj` instead of the `.sln`. If you have a multi-service solution, prefer configuring the exact application `.csproj` over the `.sln` to sidestep this entirely.

**How tests run and are reported:** `dotnet test --logger "trx;..." --collect:"XPlat Code Coverage"` against your configured test project file. Results are parsed from the TRX file's `<ResultSummary><Counters>` element; coverage from `coverage.cobertura.xml` (Cobertura format, produced by the built-in `XPlat Code Coverage` collector — no extra NuGet package needed for basic line coverage). Test-build artifacts (`obj`/`bin`) are cleaned up afterward, scoped only to your test project's own directory.

---

## Python

**Onboarding fields:** requirements file path (optional — `requirements.txt` / `pyproject.toml` / `Pipfile`, or leave blank for auto-detect), package manager (`pip` / `poetry` / `pdm` / `pipenv` / `uv`), Python version (`3.10`–`3.13`), coverage threshold. Optional: **test directory** (`tests.testDir`) — leave blank for pytest's own auto-discovery from repo root.

**How dependencies and tests are installed:** the test stage first checks for a `./vendor` virtualenv already created by the compile stage moments earlier — if your package manager is poetry/pdm/pipenv/uv, compile already installed your real dependencies there, and the test stage activates it and just adds `pytest`/`pytest-cov` on top, rather than re-running your package manager's install a second time. If no `./vendor` exists (bare pip projects, or if compile didn't run for some reason), it falls back to a fresh `pip install --user` using your configured package manager's own script under `platform/tekton/tasks/tests/scripts/python/`.

**Test-only dependencies:** if your test suite needs packages your runtime code doesn't (mocking libraries, `pytest` plugins, etc.), put them in a **`requirements-dev.txt`** file in the same directory as your main build file — this is picked up automatically and installed on top of your runtime deps, best-effort (silently skipped if you don't use this convention). Alternatively, a `pyproject.toml` with a `[test]` extra (`pip install -e ".[test]"`) is also tried automatically.

**How tests run and are reported:** `pytest --junitxml=... --cov=. --cov-report=xml:...` against your configured `testDir` (or the whole repo root if blank). Standard JUnit XML + Cobertura-style coverage XML — no special plugin configuration needed beyond having `pytest`-discoverable tests (files named `test_*.py`/`*_test.py`, functions named `test_*`, by pytest's own default convention).

**Monorepo note:** if you set `buildContext` to a subdirectory (e.g. `operator`), your `testDir` should be given the same way your app's onboarding data already expects it — the platform strips a leading `buildContext/` prefix automatically before resolving `testDir` so `buildContext=operator, testDir=operator/tests` correctly resolves to `tests` relative to the working directory, not a doubled `operator/operator/tests`. You don't need to think about this beyond entering paths as they naturally appear in your repo (i.e. `operator/tests`, not just `tests`).

---

## Node.js

**Onboarding fields:** `package.json` path, package manager (`npm` / `yarn` / `pnpm`), Node version (`18` / `20` / `22`), coverage threshold. Optional: **test script name** (`tests.testScript`, default `test`) — the `package.json` script the pipeline runs (`npm run test` / `yarn test` / `pnpm test`).

**Package manager support:** all three read the same `~/.npmrc` (private registry auth, registry-mirror config) that compile already wrote — the test stage reuses the exact same `$HOME` as compile so nothing needs reconfiguring between stages. `pnpm` specifically requires `corepack enable` under the hood since it isn't preinstalled in the base Node image the way `yarn` classic is — the platform handles this for you; you don't need a `packageManager` field or anything special in `package.json` for this to work, but do make sure your lockfile (`package-lock.json`/`yarn.lock`/`pnpm-lock.yaml`) matches your declared package manager, since a mismatched lockfile is a common source of install failures independent of anything the platform does.

**How tests run and are reported:** your configured test script is run with coverage flags appended: `--coverage --coverageReporters=cobertura --coverageDirectory=... --reporters=default --reporters=jest-junit`. This means **your test runner needs to understand Jest-style coverage/reporter CLI flags** — if you're using Jest (directly, or via a framework that wraps it — Next.js, CRA, etc.), this works out of the box as long as `jest-junit` is available as a reporter (add it to your `devDependencies` if it isn't already: `jest-junit`). If your project uses a fundamentally different test runner (Vitest, Mocha, ava) that doesn't understand these exact flags, they'll simply be ignored/passed through depending on your runner — verify your `test` script actually produces `junit.xml` and `cobertura-coverage.xml` (or a `test-results.xml`, which gets renamed to `junit.xml` automatically) in the working directory, since that's what gets parsed.

---

## React

React apps are treated identically to plain Node.js for build/test purposes (same compile task, same test task) — this section exists separately mainly because Create React App's own conventions are worth calling out specifically.

**Onboarding fields:** same as Node.js — `package.json` path, package manager, Node version, coverage threshold, optional test script (default `test`).

**How tests run:** CRA-generated projects already ship a `test` script (`react-scripts test`) — this works with the platform's coverage-flag injection as-is for most CRA setups, since `react-scripts test` is a Jest wrapper. If you've ejected from CRA or hand-rolled your Jest config, make sure `jest-junit` is configured as a reporter the same way described in the Node.js section above.

---

## Next.js

Next.js apps also share the plain Node.js compile/test tasks.

**Onboarding fields:** same as Node.js.

**How tests run:** Next.js projects typically run Jest via `npm run test`, same mechanism as plain Node.js. If your Next.js app uses the App Router with React Server Components and a testing setup like Vitest instead of Jest (increasingly common), double-check that your `test` script still honors the Jest-style coverage/reporter flags the pipeline appends, or explicitly configure your runner to emit `junit.xml`/`cobertura-coverage.xml` regardless of flags passed to it.

---

## Go

**Onboarding fields:** `go.mod` path, Go version (`1.21` / `1.22` / `1.23`), coverage threshold. Optional: **test pattern** (`tests.testPattern`, default `./...` — all packages).

**How tests run and are reported:** the test stage reuses the exact same `GOPATH`/`GOCACHE`/`GOMODCACHE` locations the compile stage already populated in the same run — this isn't optional plumbing, it's the difference between a test stage that takes ~5 seconds and one that takes ~50 seconds re-downloading/recompiling everything from scratch (confirmed via live measurement during this pipeline's development). You don't need to do anything for this — it's automatic as long as compile ran first in the same pipeline run, which it always does.

Tests run via **`gotestsum`** (pinned to `v1.12.0`, not `@latest`, for reproducible builds), which produces proper JUnit XML from Go's test output. If `gotestsum` fails to install (network blip, proxy issue), the pipeline falls back to `go test -json` and parses the JSON event stream directly — a genuine fallback built on the same underlying event data, not a degraded one. Coverage comes from `-coverprofile`, converted to a text summary via `go tool cover -func=...` and the `total:` line parsed for the percentage.

**Test pattern examples:** `./...` (default, everything), `./internal/...` (exclude integration tests living elsewhere), or any valid Go package pattern your `go test` command would otherwise accept.

---

## Rust

**Onboarding fields:** `Cargo.toml` path, Rust version (`1.75` / `1.78` / `1.81`), coverage threshold (**not actually enforced — see below**). Optional: **test filter** (`tests.testPattern`) — a `cargo test <filter>` substring filter; leave blank to run everything.

**Workspaces are supported** — `cargo build --release` / `cargo test --release` at the workspace-root `Cargo.toml` builds/tests every workspace member.

**Important: test coverage is not collected for Rust, by design.** The usual coverage tools (`cargo-tarpaulin`, `grcov`) need `ptrace` or nightly-only instrumentation, both of which are unreliable or unavailable under this platform's restricted-PSA (Pod Security Admission) test pods. Rather than report a misleading `0%`, the coverage threshold is forced to `0` internally so the gate reads as "coverage not measured" rather than "coverage failed" — **don't be alarmed by a coverage badge that never moves for Rust apps; this is expected, not a bug in your test setup.**

**How tests run and are reported:** `cargo test --release --manifest-path <Cargo.toml>` (optionally with your test filter appended). Since `cargo` has no built-in JUnit output, results are parsed from cargo's own human-readable `test result: ok. N passed; M failed; ...` summary lines (grep/awk-based — no Python available as non-root in the Rust Alpine-equivalent base image). A crate with multiple integration-test binaries produces several such summary lines, all summed. The presence of at least one `test result:` line is what distinguishes a genuine zero-test crate (`TESTS_EXECUTED=true`, 0 passed) from cargo failing before it got that far, e.g. a compile error (`TESTS_EXECUTED=false`) — both would otherwise show 0/0.

**SAST note:** `clippy` + `cargo-audit` run as this language's combined static-analysis/dependency-audit tool — no separate setup needed on your end.

---

## TypeScript

**Onboarding fields:** `package.json` path, package manager (`npm` / `yarn` / `pnpm`), Node version, coverage threshold. Optional test script (default `test`), same as Node.js.

**The one thing that's genuinely different from plain Node.js/React/Next.js:** TypeScript apps get their own dedicated **compile** task (`gitops-compile-typescript`) that runs an explicit `tsc --noEmit` type-check step, independent of and before whatever your own `package.json` build script does. **This means a type error in your code fails the pipeline's compile stage even if your own build script wouldn't have caught it or would have tolerated it.** If your project doesn't have a `tsconfig.json` at the repo root (or wherever your `tsc` config expects it), get that in order before onboarding — this is not the same forgiving "never blocks the pipeline" philosophy that applies to unit tests; a compile failure is a real, pipeline-stopping failure, same as it would be for any other language.

**How tests run:** identical to the plain Node.js test task (`gitops-test-nodejs`) — Jest-style coverage/reporter flags, `jest-junit`, same as the [Node.js section](#nodejs) above. Only compile gets special TypeScript handling; test execution doesn't need to know or care that your project happens to be TypeScript, since `jest`/`ts-jest` (or your transpiled test output) behaves the same either way once dependencies are installed.

---

## C/C++

**Onboarding fields:** Makefile path, GCC version (`12` / `13` / `14`), coverage threshold. No test filter field -- `make test` always runs the project's whole test target, there's no per-test-name filtering concept the way `cargo test`/`go test` have.

**The one thing every other build tool on this platform has that C/C++ doesn't: a dependency manager.** There's no Maven Central, no crates.io, no npm registry equivalent for plain Makefile/GCC projects -- if your build needs a third-party library, you vendor it yourself (checked-in headers/sources, a git submodule, or a system package your Dockerfile installs) or fetch it with your own `curl`/`wget` inside your Makefile. This also means there's no `extraCredentials.buildTool` option for C/C++ (no `BUILD_TOOL_LANGUAGES` entry) -- if your build genuinely needs an authenticated download, use a `secret-manager` extra credential with `section: build` instead (see the [extra credentials cheat sheet](#extra-credentials-cheat-sheet)), not the private-package-registry category the other languages use.

**Compile and test are two separate Makefile targets, on purpose:** the compile stage runs plain `make` with no target argument (your `Makefile`'s default target), and must build ONLY -- not run tests. Test stage runs `make test` explicitly, a separate target you define. This is the same convention as this platform's Ant support (`ant` vs `ant test`) for the same reason: neither build tool has a standardized "skip tests" flag the way Maven/Gradle/cargo/go do, so the platform relies on your project's own target split instead.

**Your compiled binary needs to land in `./bin`** (relative to your build context) -- same convention as this platform's Go and Rust support. Your Dockerfile then just `COPY`s it in; Kaniko never re-runs your build tool.

**Coverage is genuinely collected here, unlike Rust.** GCC's own `--coverage`/`gcov` instrumentation needs no `ptrace` or nightly-only compiler features (unlike `cargo-tarpaulin`/`grcov`, which are unreliable under this platform's restricted-PSA test pods) -- so if your `make test` target compiles with `--coverage` (or `-fprofile-arcs -ftest-coverage`) and leaves `.gcno`/`.gcda` files anywhere under your build context, the platform finds them, runs `gcov`, and reports a real percentage. **Only source files under a top-level `src/` directory are counted** -- `gcov` also reports on every transitively-included system/STL header by default, which would otherwise dominate the number with unrelated libstdc++ template-instantiation coverage that has nothing to do with your own code's test coverage.

**How tests run and are reported:** `make test` (or `make -f <your-makefile> test` if you didn't name it `Makefile`). Since C/C++ has no built-in JUnit-equivalent output and no single dominant test framework (CTest, Catch2, GoogleTest, or a hand-rolled runner are all common), results are parsed from your test target's own `test result: ok. N passed; M failed` summary line -- the exact same convention (and parsing logic) as this platform's Rust support. **Your test binary needs to print a line in that exact format** for pass/fail counts to be picked up; if you're not using a framework that already does this, write a small wrapper that does (see the `cpp-app` sample's `tests/testing.h` in the separate `k8secops/testapps` repo — not part of this repository — for a working ~40-line example with no third-party dependency).

**SAST note:** `cppcheck` runs as this language's static-analysis tool, with `--enable=warning,style,performance,portability`. Unlike every other SAST tool on this platform, cppcheck's own container image is custom-built from source (there's no official cppcheck Docker image to re-tag, and it has no non-root install mechanism the way `go install`/`cargo install`/`pip install --user` give the other runtime-installed tools) -- this is a platform-operations detail, not something that affects your onboarding.

---

## Terraform

**Onboarding fields:** none beyond language selection — Terraform apps have **no build tool, build file, build version, or test fields at all**, because there's no compile/build/test/image stage in this language's pipeline. This is intentional, not a gap: Terraform's own `.tf` files *are* the artifact being scanned, not something this platform compiles or containerizes.

**What actually runs:** `clone → secrets-scan → checkov + tflint (parallel) → ai-analysis → human-gate → done`. That's the entire pipeline — no compile stage, no unit-tests stage, no Docker build, no image push, no signing. Checkov (`.tf`/`.tf.json`, with `.terraform/` and `.terragrunt-cache/` excluded so generated/vendored files don't get scanned) and tflint (`--recursive`, so submodules under `modules/`, `environments/*`, etc. are covered) both run **on by default** for this language specifically — this is the one case where IaC scanning is genuinely in-scope for this platform, unlike a normal app repo's own deployment manifests (see [core-principles/07-ci-only-scope-discipline.md](../core-principles/07-ci-only-scope-discipline.md)).

**If you're onboarding a Terraform repo expecting a `unit-tests` stage or a coverage number**, there isn't one — this is a scan-only language, and "testing" your Terraform means the security/IaC scanners themselves, not a unit test suite.

---

## Extra credentials cheat sheet

If your build or test suite needs a credential beyond your git token and image registry, you declare it during onboarding (or via Edit App) as one of four categories — get the category right, since it controls both *when* the credential is available and whether it's ever visible to code beyond what needs it:

| Category | Available at | Typical use |
|---|---|---|
| `build-artifact-repo` | Compile only | Private package registry auth (a private Maven repo, private npm registry, private PyPI index, private NuGet feed, private Go module proxy, private Cargo registry) — matched to your build file's existing `<server>`/registry host reference via `matchId` for Maven/npm/NuGet/Go/pip |
| `secret-manager`, `section: build` | Compile only | Any other build-time-only secret, delivered as an env var or a file (SSH deploy keys, CA certs, kubeconfigs) |
| `secret-manager`, `section: test` | Test only | A credential your test suite reads but your build doesn't need |
| `secret-manager`, `section` unset / `external-service` (legacy) | Both compile and test | Database/Redis/Kafka/curl-scp-wget targets your tests hit at runtime |

**Cargo/Rust is the one exception to the `matchId` convention above:** for a private Cargo registry credential, the platform writes `[registries.<name>]` into `~/.cargo/credentials.toml` using the credential's own **`name`** field as the registry alias — not `matchId`. This means whatever you name the credential during onboarding must exactly match the registry alias your own `.cargo/config.toml`'s `[source.*]`/`[registries.*]` block already references, not a host you're matching against. Every other language in the table above genuinely uses `matchId` as documented.

**How your test code actually sees these:** for `env`-delivery credentials, the exact environment variable name you declared (`envVarName`) is set directly — your test code just reads `os.environ["MY_VAR"]` / `process.env.MY_VAR` / `Environment.GetEnvironmentVariable("MY_VAR")` etc. as normal, no platform-specific code needed. For `file`-delivery credentials (SSH keys, certs), your code gets `{envVarName}_FILE` pointing at a mounted file path instead of the raw value in an env var. Values are never embedded as literal text into a generated shell line — they're deferred-read from the mounted Secret file at the point your test step sources them, so multi-line content or literal quotes in a credential value can't break anything.

---

## Troubleshooting checklist

Before assuming a platform bug when your test stage doesn't look right:

1. **Check `TESTS_EXECUTED`, not just pass/fail counts.** `0 passed, 0 failed, executed=false` means your test runner never ran at all — look at the `test`/`run-tests` step's own logs (not the `parse-results` step, which only reports what it found) for the actual install/invocation failure.
2. **A red test suite does not mean a stopped pipeline** — check the run's test/coverage panel directly at the human gate rather than inferring pass/fail from whether the pipeline reached the gate at all (see [the philosophy section](#the-one-philosophy-you-need-to-internalize)).
3. **Coverage reading as 0% for Java** almost always means the JaCoCo plugin isn't configured in your `pom.xml`/`build.gradle` — tests can still be passing correctly.
4. **Coverage reading as 0% for Rust is expected, not a bug** — coverage isn't collected for this language at all (see [Rust](#rust)).
5. **.NET test discovery failing** — double check `tests.testFile` points at your *test* project's `.csproj`, not your application's, and that the SDK version you configured matches your project's `TargetFramework`.
6. **A misconfigured `build-file`/`dockerfile-path`/`test-dir` might silently self-correct** via `ai-preflight` — deterministically if there's exactly one real candidate on disk, or via a constrained AI pick if there are several and your app has AI credentials configured. Check the preflight step's own log output (or the run's AI report — it writes there too) to see if this happened before assuming your onboarding config is being ignored. **`build-context` is never touched by this mechanism** — a wrong `build-context` fails loudly at Kaniko/compile time instead, with no auto-recovery. If you're chasing a recurring path error, check `build-context` by hand first.
7. **Monorepo paths not resolving** — confirm `buildContext` and your language's test-directory-style field (`testDir`, `testFile`, etc.) are both given consistently relative to repo root, not relative to `buildContext` itself; the platform strips the `buildContext/` prefix for you, but only when your value is actually prefixed with it.
8. **A TypeScript compile failure on a type error you weren't expecting to block the build** — this is deliberate (see [TypeScript](#typescript)); fix the type error rather than looking for a way to skip the check, since there isn't a supported way to disable `tsc --noEmit` short of fixing your `tsconfig.json`'s strictness settings.
9. **Coverage reading as 0% for C/C++** — unlike Rust, this isn't expected; it means your `make test` target didn't compile with `--coverage`/`-fprofile-arcs -ftest-coverage`, or no `.gcno`/`.gcda` files were left anywhere under your build context for the platform's `gcov` step to find (see [C/C++](#cc)). Check the `test` step's own logs for whether any `gcov` output was produced at all.
