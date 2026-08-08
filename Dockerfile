FROM nocodb/nocodb:2026.08.0

# Literals a Railway template variable cannot carry: `templateGenerate` drops a
# literal defaultValue and republishes the variable as a blank required field,
# so anything the image already knows is baked here instead of in the template.
ENV NC_DISABLE_TELE=true \
    NC_TOOL_DIR=/usr/app/data/

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/railway-entrypoint.sh"]
