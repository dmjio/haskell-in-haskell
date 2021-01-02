#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/// exit the program, displaying an error message
void panic(const char *message) {
  fputs("PANIC:", stderr);
  fputs(message, stderr);
  exit(-1);
}

/// A code label takes no arguments, and returns the next function.
///
/// We have to return a void*, because we can't easily have a recursive
/// type here. But, this is basically always an `EntryFunction*`.
typedef void *(*CodeLabel)(void);

/// An InfoTable contains the information about the functions of a closure
typedef struct InfoTable {
  /// The function we can call to enter the closure
  CodeLabel entry;
} InfoTable;

/// We provide an entry function for a string that always fails
void *string_entry() {
  panic("attempted to call a string's entry function");
  return NULL;
}

/// The Infotable we use for strings
///
/// The entry should never be called, so we provide a panicking function
InfoTable table_for_string = {&string_entry};
static InfoTable *table_pointer_for_string = &table_for_string;

/// The InfoTable we use for string literals
InfoTable table_for_string_literal = {&string_entry};

/// A data structure representing our global Heap of memory
typedef struct Heap {
  /// The data contained in this heap
  uint8_t *data;
  /// The part of the data we're currently writing to
  uint8_t *cursor;
  /// The total capacity of the data, in bytes
  size_t capacity;
} Heap;

/// "The Heap", as a global variable.
///
/// This is static, since we always use it through functions provided
/// in this runtime file.
static Heap g_Heap = {NULL, NULL, 0};

/// Grow the heap, removing useless objects
void collect_garbage() {
  panic("I don't know how to collect garbage");
}

/// Reserve a certain amount of bytes in the Heap
///
/// The point of this function is to trigger garbage collection, growing
/// the Heap, if necessary.
///
/// No bounds checking of the Heap is done otherwise.
void heap_reserve(size_t amount) {
  // We'd need to write beyond the capacity of our buffer
  if (g_Heap.cursor + amount > g_Heap.data + g_Heap.capacity) {
    collect_garbage();
  }
}

/// Concat two strings together, returning the location of the new string
///
/// This might trigger garbage collection. In practice, we only ever do
/// this right before jumping to a continuation, so this is ok.
uint8_t *string_concat(uint8_t *s1, uint8_t *s2) {
  uint8_t *data1 = s1 + sizeof(InfoTable *);
  uint8_t *data2 = s2 + sizeof(InfoTable *);
  size_t len1 = strlen((char *)data1);
  size_t len2 = strlen((char *)data2);

  size_t required = sizeof(InfoTable *) + len1 + len2 + 1;
  if (g_Heap.cursor + required > g_Heap.data + g_Heap.capacity) {
    // TODO: Also evacuate the two strings, so we know where the data goes
    collect_garbage();
  }

  uint8_t *ret = g_Heap.cursor;

  memcpy(g_Heap.cursor, &table_pointer_for_string, sizeof(InfoTable *));
  g_Heap.cursor += sizeof(InfoTable *);
  memcpy(g_Heap.cursor, data1, len1 + 1);
  g_Heap.cursor += len1 + 1;
  memcpy(g_Heap.cursor, data2, len2 + 1);
  g_Heap.cursor += len2 + 1;

  return ret;
}

/// Get a current cursor, where writes to the Heap will happen
uint8_t *heap_cursor() {
  return g_Heap.cursor;
}

void heap_write(void *data, size_t bytes) {
  memcpy(g_Heap.cursor, data, bytes);
  g_Heap.cursor += bytes;
}

/// Write a pointer into the heap
void heap_write_ptr(uint8_t *ptr) {
  heap_write(&ptr, sizeof(uint8_t *));
}

/// Write an info table pointer into the heap
void heap_write_info_table(InfoTable *ptr) {
  heap_write(&ptr, sizeof(InfoTable *));
}

/// Write an integer into the heap
void heap_write_int(int64_t x) {
  heap_write(&x, sizeof(int64_t));
}

/// Read a ptr from a chunk of data
uint8_t *read_ptr(uint8_t *data) {
  uint8_t *ret;
  memcpy(&ret, data, sizeof(uint8_t *));
  return ret;
}

/// Read a 64 bit integer from a chunk of data
int64_t read_int(uint8_t *data) {
  int64_t ret;
  memcpy(&ret, data, sizeof(int64_t));
  return ret;
}

/// Read a pointer to an info table from a chunk of data
InfoTable *read_info_table(uint8_t *data) {
  InfoTable *ret;
  memcpy(&ret, data, sizeof(InfoTable *));
  return ret;
}

/// Represents the argument stack
///
/// Each argument represents the location in memory where the closure
/// for that argument is stored. You can sort of think of this as InfoTable**.
typedef struct StackA {
  /// The top of the argument stack.
  ///
  /// The stack grows upward, with the current pointer always
  /// pointing at valid memory, but containing no "live" value.
  uint8_t **top;
  /// The base pointer of the argument stack.
  ///
  /// We need to keep this around to free the stack on program exit.
  uint8_t **base;
} StackA;

/// The "A" or argument stack
StackA g_SA = {NULL, NULL};

/// Represents an item on the secondary stack.
///
/// This is either a pointer to string data, a 64 bit integer, or a function
/// pointer for a continuation.
typedef union StackBItem {
  int64_t as_int;
  CodeLabel as_continuation;
} StackBItem;

/// Represents the secondary stack.
///
/// This contains various things: ints, strings, and continuations.
typedef struct StackB {
  StackBItem *top;
  StackBItem *base;
} StackB;

/// The secondary stack
StackB g_SB = {NULL, NULL};

/// The register holding integer returns
int64_t g_IntRegister = 0xBAD;
/// The register holding string values
///
/// This is **not** a pointer to the character data, but rather,
/// the location in memory where this string closure resides.
uint8_t *g_StringRegister = NULL;
/// The register holding constructor tag returns
int64_t g_TagRegister = 0xBAD;
/// The register holding the number of constructor args returned
int64_t g_ConstructorArgCountRegister = 0xBAD;
/// The register holding the location of the current closure
uint8_t *g_NodeRegister = NULL;

/// The starting size for the Heap
static const size_t BASE_HEAP_SIZE = 1 << 16;
/// The starting size for each Stack
static const size_t STACK_SIZE = 1 << 10;

/// Setup all the memory areas that we need
void setup() {
  g_Heap.data = malloc(BASE_HEAP_SIZE * sizeof(uint8_t *));
  if (g_Heap.data == NULL) {
    panic("Failed to initialize Heap");
  }
  g_Heap.cursor = g_Heap.data;
  g_Heap.capacity = BASE_HEAP_SIZE;

  g_SA.base = malloc(STACK_SIZE * sizeof(InfoTable *));
  if (g_SA.base == NULL) {
    panic("Failed to initialize Argument Stack");
  }
  g_SA.top = g_SA.base;

  g_SB.base = malloc(STACK_SIZE * sizeof(StackBItem));
  if (g_SB.base == NULL) {
    panic("Failed to initialize Secondary Stack");
  }
  g_SB.top = g_SB.base;
}

/// Cleanup all the memory areas that we've created
void cleanup() {
  free(g_Heap.data);
  free(g_SA.base);
  free(g_SB.base);
}
