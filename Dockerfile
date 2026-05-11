FROM nginx:alpine

COPY . /usr/share/nginx/html

RUN rm -f /usr/share/nginx/html/default.conf

EXPOSE 80
