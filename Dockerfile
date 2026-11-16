
FROM nginx:alpine

ARG APP_VERSION=BLUE

COPY website/index.html /usr/share/nginx/html/index.html

RUN sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" /usr/share/nginx/html/index.html

EXPOSE 80
