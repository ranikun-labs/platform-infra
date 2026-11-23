FROM nginx:1.27-alpine
RUN apk add --no-cache jq
COPY nginx.conf /etc/nginx/templates/carelog.conf
COPY proxy-entrypoint.sh /usr/local/bin/carelog-proxy
RUN chmod 755 /usr/local/bin/carelog-proxy
ENTRYPOINT ["/usr/local/bin/carelog-proxy"]
