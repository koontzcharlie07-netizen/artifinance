# Artifinance

## Build and run

Requirements: Ruby 3.4.9, PostgreSQL, Redis, and the system packages listed in
the `Dockerfile`.

```sh
docker build -t artifinance .
docker run --rm -p 3000:3000 \
  -e DATABASE_URL=postgres://user:password@host/artifinance \
  -e REDIS_URL=redis://host:6379/1 \
  -e SECRET_KEY_BASE=replace-with-a-random-secret \
  -e APP_DOMAIN=localhost \
  -e ONBOARDING_STATE=closed \
  artifinance
```

The container entrypoint runs database migrations before starting Rails.
Optional integrations use the environment variables listed in `.env.example`.

## AGPL source notice

This is the corresponding source for the Artifinance network service and is
licensed under the GNU Affero General Public License version 3. The source is
published at [github.com/koontzcharlie07-netizen/artifinance](https://github.com/koontzcharlie07-netizen/artifinance).
See `LICENSE` and `NOTICE`.
