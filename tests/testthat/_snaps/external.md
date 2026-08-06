# nested columns are skipped with one message per operation

    Code
      result <- read_parquet(path)
    Message
      Skipping 12 nested Parquet columns; nested reading is deferred to qio 0.2.0.

---

    Code
      empty <- collect(file, columns = "int_array.list.element")
    Message
      Skipping 1 nested Parquet column; nested reading is deferred to qio 0.2.0.

---

    Code
      walk_batches(file, function(batch, index) dimensions[[index]] <<- dim(batch),
      batch_size = 3L)
    Message
      Skipping 12 nested Parquet columns; nested reading is deferred to qio 0.2.0.

