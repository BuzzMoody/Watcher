# Use a lightweight base image with necessary packages
FROM alpine:latest

# Set the timezone you want
ENV TZ=Australia/Melbourne

# Install required packages
# tzdata → timezone database
# rsync, openssh-client, inotify-tools, bash → your needed tools
RUN apk add --no-cache tzdata rsync openssh-client inotify-tools bash \
    && cp /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && apk del tzdata

# Set the working directory
WORKDIR /app

# Copy the bash script into the container
COPY transfer_watcher.sh /app/transfer_watcher.sh

# Give execution rights to the script
RUN chmod +x /app/transfer_watcher.sh

# Create the .ssh directory and set permissions (required for ssh key)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Default command
CMD ["/app/transfer_watcher.sh"]
