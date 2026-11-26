# nested columns qio cannot read are skipped with one message

    Code
      result <- read_parquet(path)
    Message
      Skipping 7 nested Parquet columns that qio cannot read: `int_array_Array` (nested list), `int_Map_Array` (list of maps), `nested_struct.C.d` (nested list), `nested_struct.g` (map with group keys or values).

---

    Code
      walk_batches(file, function(batch, index) dimensions[[index]] <<- dim(batch),
      batch_size = 3L)
    Message
      Skipping 12 nested Parquet columns: walk_batches() reads flat columns only; use collect().

