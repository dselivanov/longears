testthat::context("test-consume.R")

testthat::test_that("Consume works as expected", {
  skip_if_no_local_rmq()

  conn <- amqp_connect()

  # Must create consumers first.
  testthat::expect_error(
    amqp_listen(conn),
    regexp = "No consumers are declared on this connection"
  )

  messages <- data.frame()
  f1 <- function(msg) {
    messages <<- rbind(messages, as.data.frame(msg))
    msg$delivery_tag > 1
  }

  count <- 0
  f2 <- function(msg) {
    count <<- count + 1
  }

  alt_count <- 0
  f3 <- function(msg) {
    alt_count <<- alt_count + 1
  }

  amqp_declare_exchange(conn, "test.exchange", auto_delete = TRUE)
  q1 <- amqp_declare_tmp_queue(conn)
  amqp_bind_queue(conn, q1, "test.exchange", routing_key = "#")
  q2 <- amqp_declare_tmp_queue(conn)
  amqp_bind_queue(conn, q2, "test.exchange", routing_key = "#")
  q3 <- amqp_declare_tmp_queue(conn)
  amqp_bind_queue(conn, q3, "test.exchange", routing_key = "#")

  c1 <- testthat::expect_silent(amqp_consume(conn, q1, f1))
  c2 <- testthat::expect_silent(amqp_consume(conn, q2, f2))
  c3 <- testthat::expect_silent(amqp_consume(conn, q3, f3))

  amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  )
  amqp_publish(
    conn, body = "Hello, again", exchange = "test.exchange", routing_key = "#"
  )

  amqp_listen(conn, timeout = 1)

  testthat::expect_equal(nrow(messages), 2)
  testthat::expect_equal(count, 2)
  testthat::expect_equal(alt_count, 2)

  amqp_delete_queue(conn, q3)
  amqp_publish(
    conn, body = "Goodbye", exchange = "test.exchange", routing_key = "#"
  )

  testthat::expect_silent(amqp_cancel_consumer(c1))

  testthat::expect_error(
    amqp_cancel_consumer(c1), regexp = "Invalid consumer object"
  )

  amqp_listen(conn, timeout = 1)

  # We don't want the cancelled consumer's callback to have been called again.
  testthat::expect_equal(nrow(messages), 2)

  # We don't expect the callback for the deleted queue to have been called.
  testthat::expect_equal(alt_count, 2)

  # But we do expect this one to have been called.
  testthat::expect_equal(count, 3)

  testthat::expect_silent(amqp_cancel_consumer(c3))
  testthat::expect_silent(amqp_cancel_consumer(c2))

  testthat::expect_error(
    amqp_listen(conn),
    regexp = "No consumers are declared on this connection"
  )

  amqp_disconnect(conn)
})

testthat::test_that("Consumers respond to disconnections correctly", {
  skip_if_no_local_rmq()
  skip_if_no_rabbitmqctl()

  conn <- amqp_connect()

  messages <- data.frame()
  f1 <- function(msg) {
    messages <<- rbind(messages, as.data.frame(msg))
    msg$delivery_tag > 1
  }

  # We need durable queues/exchanges to test across server restarts.
  amqp_delete_exchange(conn, "test.exchange")
  amqp_declare_exchange(conn, "test.exchange", durable = TRUE)
  amqp_declare_queue(conn, queue = "test.queue", durable = TRUE)
  amqp_bind_queue(conn, "test.queue", "test.exchange", routing_key = "#")

  c1 <- testthat::expect_silent(amqp_consume(conn, "test.queue", f1))

  # Simulate an unexpected disconnection.
  testthat::expect_equal(rabbitmqctl("stop_app"), 0)
  testthat::expect_equal(rabbitmqctl("start_app"), 0)

  testthat::expect_error(amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  ), regexp = "Disconnected from server")

  testthat::expect_warning(amqp_reconnect(conn), regexp = "must be recreated")

  amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  )

  # The consumer should not trigger.
  testthat::expect_silent(amqp_listen(conn, 1))
  testthat::expect_equal(nrow(messages), 0)

  # Unnecessary cancels should not cause a crash.
  testthat::expect_silent(amqp_cancel_consumer(c1))

  amqp_delete_queue(conn, "test.queue")
  amqp_delete_exchange(conn, "test.exchange")
  amqp_disconnect(conn)
})

testthat::test_that("Consume later works as expected", {
  skip_if_no_local_rmq()

  conn <- amqp_connect()

  amqp_declare_exchange(
    conn, "test.exchange", type = "direct", auto_delete = TRUE
  )
  q1 <- amqp_declare_tmp_queue(conn, exclusive = FALSE)
  amqp_bind_queue(conn, q1, "test.exchange", routing_key = "#")
  q2 <- amqp_declare_tmp_queue(conn, exclusive = FALSE)
  amqp_bind_queue(conn, q2, "test.exchange", routing_key = "#")

  messages <- data.frame()
  last_tag <- NA

  # Create two consumers.

  c1 <- testthat::expect_silent(
    amqp_consume_later(conn, q1, function(msg) {
      messages <<- rbind(messages, as.data.frame(msg))
    })
  )

  c2 <- testthat::expect_silent(
    amqp_consume_later(conn, q2, function(msg) {
      last_tag <<- msg$delivery_tag
    })
  )

  amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  )

  # Ensure that the callbacks trigger.
  expect_callbacks(2)

  amqp_publish(
    conn, body = "Hello, again", exchange = "test.exchange", routing_key = "#"
  )

  # Ensure that the callbacks trigger.
  expect_callbacks(2)

  testthat::expect_equal(nrow(messages), 2)
  testthat::expect_false(is.na(last_tag))

  testthat::expect_silent(amqp_cancel_consumer(c1))
  testthat::expect_error(amqp_cancel_consumer(c1), regexp = "destroyed")
  testthat::expect_silent(amqp_cancel_consumer(c2))
  amqp_disconnect(conn)
})

testthat::test_that("Consume later responds to disconnections correctly", {
  skip_if_no_local_rmq()
  skip_if_no_rabbitmqctl()

  conn <- amqp_connect()

  f1 <- function(msg) {
    invisible(NULL)
  }

  # We need durable queues/exchanges to test across server restarts.
  amqp_delete_exchange(conn, "test.exchange")
  amqp_delete_queue(conn, "test.queue")
  amqp_declare_exchange(conn, "test.exchange", durable = TRUE)
  amqp_declare_queue(conn, queue = "test.queue", durable = TRUE)
  amqp_bind_queue(conn, "test.queue", "test.exchange", routing_key = "#")

  c1 <- testthat::expect_silent(amqp_consume_later(conn, "test.queue", f1))

  amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  )

  # Ensure that the callback triggers.
  expect_callbacks(1)

  # Simulate an unexpected disconnection.
  testthat::expect_equal(rabbitmqctl("stop_app"), 0)
  testthat::expect_equal(rabbitmqctl("start_app"), 0)

  testthat::expect_error(amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  ), regexp = "Disconnected from server")

  amqp_reconnect(conn)

  # Esnure the warning callback runs.
  testthat::expect_warning(wait_for_callbacks(1), regexp = "must be recreated")

  c2 <- testthat::expect_silent(amqp_consume_later(conn, "test.queue", f1))

  amqp_publish(
    conn, body = "Hello, world", exchange = "test.exchange", routing_key = "#"
  )

  # Unnecessary cancels should not cause a crash.
  testthat::expect_silent(amqp_cancel_consumer(c1))

  # Ensure that the callback triggers.
  expect_callbacks(1)

  amqp_delete_queue(conn, "test.queue")
  amqp_delete_exchange(conn, "test.exchange")
  amqp_disconnect(conn)
})
