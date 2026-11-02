# openedx-status-web

A small static status page (plain HTML, CSS and JavaScript) served by nginx. It reads its data from
[openedx-status-api](https://github.com/Abstract-Tech/openedx-status-api) and refreshes every 30 seconds.

## How it works with the API

The page asks for `api/status`. nginx passes every request under `/api/` on to `http://status-api:8000`,
so the API must be reachable under the host name `status-api` on port 8000 (for example, a container
with that name on the same Docker network). nginx re-resolves the name all the time, so the page still
starts if the API is not there yet.

The container listens on port 8080, runs as a non-root user, and answers `/healthz` with `ok`.

## Run it

    docker run -d --name status-web --network <network-with-status-api> -p 8080:8080 \
      ghcr.io/abstract-tech/openedx-status-web:0.1.2

The easiest way is [openedx-status-deploy](https://github.com/Abstract-Tech/openedx-status-deploy). It starts
the API, this page and a proxy together.

To build it yourself: `docker build -t openedx-status-web .`

## When the API is down

nginx keeps the last good answer from the API. If the API stops answering, visitors still see that
cached data. When the data is older than three minutes, or cannot be refreshed, the page shows a notice
such as "The status monitor is not reporting. Showing the last known data from 14:05." If there is no
data at all, the banner says "Status unavailable".

## Restyle or rename

- The page title comes from the API (the `STATUS_TITLE` setting in openedx-status-api), not from this repo.
- Colors and layout are in `assets/status.css`. The colors are CSS variables at the top of the file,
  with a dark mode variant.
- The icon is `assets/favicon.svg`.
- Rebuild the image after any change.

## Related repositories

- [openedx-status-api](https://github.com/Abstract-Tech/openedx-status-api): the backend that does the checks
- [tutor-contrib-status](https://github.com/Abstract-Tech/tutor-contrib-status): Tutor plugin to run the status page

## License

MIT, see [LICENSE](LICENSE).
