# Use a lightweight base image with necessary packages
FROM alpine:latest

# Install rsync, openssh-client (for ssh), inotify-tools, and bash
RUN apk add --no-cache rsync openssh-client inotify-tools bash

# Set the working directory
WORKDIR /app

# Copy the bash script into the container
COPY transfer_watcher.sh /app/transfer_watcher.sh

# Give execution rights to the script
RUN chmod +x /app/transfer_watcher.sh

# Create the .ssh directory and set permissions (required for ssh key)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# The default command when the container starts
CMD ["/app/transfer_watcher.sh"]