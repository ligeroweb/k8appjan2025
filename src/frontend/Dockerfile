FROM nginx:alpine

# Copy static files to Nginx directory
COPY index.html /usr/share/nginx/html/index.html

# Copy a custom nginx config if you need reverse proxying
# COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]