FROM alpine:latest

# Default timezone
ENV TZ=Australia/Melbourne

# Install required packages including tzdata (keep it!)
RUN apk add --no-cache \
	tzdata \
	rsync \
	openssh-client \
	inotify-tools \
	bash

# Set timezone
RUN cp /usr/share/zoneinfo/${TZ} /etc/localtime \
	&& echo "${TZ}" > /etc/timezone

# Set working directory
WORKDIR /app

# Copy watcher script and health check script
COPY transfer_watcher.sh /app/transfer_watcher.sh
COPY health_check.sh /app/health_check.sh
RUN chmod +x /app/transfer_watcher.sh /app/health_check.sh

# Ensure .ssh folder exists
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Health check instruction
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD ["/app/health_check.sh"]

# Run the script directly
CMD ["/app/transfer_watcher.sh"]