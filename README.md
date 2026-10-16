# drupal-contrib local CI

A Docker Compose project that runs the Drupal.org GitLab CI template locally, using [gitlab-ci-local](https://github.com/firecow/gitlab-ci-local), against the contrib module repos that sit in this folder. It exists so CI failures show up before anything is pushed to drupal.org.

It works with **any Drupal.org contrib module**. Clone as many module repos as you like as sibling directories here; the harness detects them automatically. Each module is a separate git repository that this folder's own repository ignores.

## Requirements

- Docker Desktop running on the Mac. The harness was built and tested on Apple Silicon (aarch64) with Docker 29.4.1.
- Network access to `git.drupalcode.org` (HTTPS) and to the container registries the template pulls from.
- A `.env` file in this folder, which is git-ignored. Create it with these values:

```
MODULES_DIR=/Users/dietrichgottfriedschmidt/apps/drupal-contrib
TEMPLATES_REPO=project/gitlab_templates
TEMPLATES_REF=main
```

`TEMPLATES_REF` should match what your real pipeline on drupal.org resolves to, because the results depend on the template version.

## Adding a module

1. Clone the drupal.org project repo as a sibling of this folder:

```bash
git clone https://git.drupal.org/project/my_module.git
```

2. Run any make command with `MODULE=my_module`:

```bash
make fast MODULE=my_module
make ci MODULE=my_module
make phpunit MODULE=my_module
```

That is all. No configuration is needed. The harness discovers any directory in this folder that contains a `.git` subdirectory.

## Commands

Run these from this folder, one at a time. Two runs against the same module collide.

| Command | What it runs |
|---|---|
| `make build` | Builds the CI image. Rebuild after editing `drupal-ci.sh`, because the script is baked into the image. |
| `make fast` | phpcs, phpstan and cspell |
| `make ci` | composer, phpcs, phpstan, cspell, eslint and stylelint. phpunit is left out on purpose. |
| `make phpunit` | phpunit alone, with amd64 job images |
| `make list MODULE=<name>` | The jobs the template defines for one module |
| `make origins` | Each module's origin URL |

Add `MODULE=<name>` to limit a run to one module. Add `JOBS="phpcs phpstan"` to `make ci` to choose jobs. Jobs a module does not define are skipped.

A pipeline takes about 3 minutes per module. The first run after a Docker restart is slower, because images are pulled again.

## Reading the output

Each job prints `PASS`, `WARN` or `FAIL`, followed by a pipeline time per module. A run ends with `All modules passed.` or a `Failed:` line listing modules.

Some output is harmless:

- stylelint prints `NoFilesFoundError` when a module has no CSS files.
- `git config user.email` exit-code-1 lines.
- A notice that `origin/HEAD` is not a symbolic ref.

stylelint is not defined at all for modules without CSS on a clean checkout, so it is skipped.

## How it works, and why

The design came from specific problems found while building it.

1. **Template includes come from an HTTPS clone.** The module origins are `git@git.drupal.org:project/<module>.git`. gitlab-ci-local fetches `project:` includes with `git archive --remote` over SSH, which drupal.org does not serve. So `drupal-ci.sh` clones `project/gitlab_templates` over HTTPS at `TEMPLATES_REF` into the `gcl-home` Docker volume, then copies it into gitlab-ci-local's include cache.
2. **Each run works on a copy of the module in the Docker volume.** Reading many small files through the macOS bind mount was very slow. A plain `find` over about 41,000 files took 10 minutes, and exporting job artifacts took 8 minutes. The script now syncs the module into `/gcl-home/work/<module>` with rsync, skipping `vendor/` and `node_modules/`, and keeps gitlab-ci-local state in `/gcl-home/state/<module>`. The module folders are only read, never written, and `docker-compose.yml` mounts them read-only to enforce that.
3. **The sync uses `--delete-excluded`.** Without it, output left from earlier runs (such as `web/`) stays in the copy and changes what the template's `exists:` rules see.
4. **phpunit runs on amd64.** Its `selenium/standalone-chrome` service image has no arm64 build. `make phpunit` sets `JOB_PLATFORM=linux/amd64`, and the script applies it as `DOCKER_DEFAULT_PLATFORM` only around gitlab-ci-local. Do not set `DOCKER_DEFAULT_PLATFORM` on the compose command line, because Compose would try to run the arm64 CI image as amd64. Switching between `make ci` and `make phpunit` re-pulls about 1 GB of DrupalCI images, because both use the same image tag.
5. **Jobs are listed once per module,** because `gitlab-ci-local --list` scans the whole working copy.

## Performance

Measured on Apple Silicon with Docker Desktop (server 29.4.1) against `content_syndication`, running `phpcs`. Each figure is one run unless a range is given, so treat small differences as noise.

**Bind mount versus Docker volume.** A synthetic test (3000 small files, five runs, medians) showed the bind mount is far slower for small files and about the same for large sequential writes. Creating the files took 1490 ms on the bind mount and 60 ms on a volume. Stat took 170 ms against 20 ms. This is why each run works on a copy in the `gcl-home` volume. The test did not identify the file sharing backend. Check Docker Desktop under Settings, General to see whether VirtioFS is on.

**Where a run spends its time.**

| Step | Time |
|---|---|
| rsync of the module into the volume | about 0.1 s when unchanged, about 1.7 s after a build |
| seed template includes | about 0.7 s |
| list jobs | about 6 s |
| `composer` job | 1.4 min without the cache, 1.1 min with a warm cache |
| `phpcs` job | 15 to 17 s |

Each step prints a `[timing]` line to stderr.

**What helped.**

- **Composer cache.** Job containers mount the named volume `composer-cache` and set `COMPOSER_CACHE_DIR`. A warm cache cut `composer` from about 85 s to about 65 s and removed all 193 downloads. The volume is about 370 MB. Turn it off with `COMPOSER_CACHE=0`, and clear it with `docker volume rm composer-cache`.
- **Run jobs together.** `make ci JOBS="phpcs phpstan cspell"` took 150 s, against 129 s for `phpcs` alone, because `composer` runs once per invocation. Separate invocations pay for it each time.

**What did not help.** Keeping `vendor/` and `web/` in the volume copy between runs left `composer` at 1.4 min. The job still reported no `composer.lock` and downloaded the same packages. Why `gitlab-ci-local` ignores the kept files was not investigated.

## Differences from the real pipeline

- The local copy includes untracked files in a module, which GitLab would not see.
- Results depend on `TEMPLATES_REF`, which may differ from the template version drupal.org uses on the day of a push.
- Jobs run in the DrupalCI images through the host Docker socket, which `docker-compose.yml` mounts.

## Rules for working here

- Never run gitlab-ci-local directly inside a module folder. It writes `web/`, `vendor/` and a modified `composer.json` into the module.
- Do not commit or push in the module repos as part of a CI run.
- `docker-compose.yml` mounts `~/.ssh` read-only. Template includes now come over HTTPS, so the mount is probably unneeded, but that has not been confirmed.

## Troubleshooting

- **Docker is not running or fails to start.** Start Docker Desktop first. If `docker info` still fails, quit Docker Desktop fully and reopen it. Avoid "Clean / Purge data" and "Reset to factory defaults", which delete every volume and image on the machine.
- **A stale working copy.** The cache is regenerable. To clear the per-module copies and state, run `docker run --rm -v drupal-contrib_gcl-home:/v alpine sh -c 'rm -rf /v/work /v/state'`. The volume name comes from this folder's name. The first run afterwards is slower.
- **`no matching manifest for linux/arm64/v8`.** A job image has no arm64 build. Run phpunit with `make phpunit`. If another job hits this, a per-job platform setting is needed.
- **A missing `.env`.** Compose fails with `MODULES_DIR` unset. Create it as shown above.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Node image with git, rsync, the Docker CLI and gitlab-ci-local |
| `docker-compose.yml` | The `ci` service, mounts and environment |
| `drupal-ci.sh` | The runner, which syncs modules, seeds the template cache and runs jobs |
| `Makefile` | The commands above |
| `.env` | Local settings, git-ignored |
| `HANDOFF.md` | A brief for a coding agent taking over review and execution, git-ignored |
