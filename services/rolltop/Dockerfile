FROM ghcr.io/grahamsz/rolltop:latest
# GOTCHA / PATCH: upstream :latest ships the `mail_filters` plugin manifest
# (backend kind=go-plugin) but omits the compiled mail_filters.so, which makes
# the plugin loader abort at startup with "realpath failed". We delete the
# broken plugin so the loader skips it. Must switch to root to remove the
# root-owned files, then drop back to the unprivileged uid.
USER root
RUN rm -rf /app/plugins/mail_filters
USER 1000
