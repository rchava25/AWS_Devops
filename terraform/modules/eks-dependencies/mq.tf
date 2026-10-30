# Amazon MQ has been replaced by Amazon SQS for the orders messaging queue.
# See sqs.tf for the active configuration.
#
# This file intentionally contains no resources. The retail-store-sample orders
# service supports SQS as a native messaging provider, so RabbitMQ is no longer
# needed. Removing the broker saves ~$0.30/hr and 15-30 min of provision time.
