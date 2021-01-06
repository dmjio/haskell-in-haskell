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

#ifdef DEBUG
#define DEBUG_PRINT(...)                                                       \
  do {                                                                         \
    fprintf(stderr, __VA_ARGS__);                                              \
  } while (0)
#else
#define DEBUG_PRINT(...)                                                       \
  do {                                                                         \
  } while (0)
#endif

/// A code label takes no arguments, and returns the next function.
///
/// We have to return a void*, because we can't easily have a recursive
/// type here. But, this is basically always an `EntryFunction*`.
typedef void *(*CodeLabel)(void);

/// An evac function takes the current location of a closure,
/// and returns the new location after moving that closure (if necessary).
typedef uint8_t *(*EvacFunction)(uint8_t *);

/// An InfoTable contains the information about the functions of a closure
typedef struct InfoTable {
  /// The function we can call to enter the closure
  CodeLabel entry;
  /// The evacuation function we call to collect this closure
  EvacFunction evac;
} InfoTable;

/// For static objects, evacuating them should return their current location
uint8_t *static_evac(uint8_t *base) {
  return base;
}

/// It's useful for to have a null table to use that's valid for the GC,
/// but can't be entered
InfoTable table_for_null = {NULL, &static_evac};
static InfoTable *table_pointer_for_null = &table_for_null;

/// For closures that have already been evacuated
uint8_t *already_evac(uint8_t *base) {
  uint8_t *ret;
  memcpy(&ret, base + sizeof(InfoTable *), sizeof(uint8_t *));
  return ret;
}

/// A table we can share between closures that are already evacuated
InfoTable table_for_already_evac = {NULL, &already_evac};
/// A pointer to the above table
static InfoTable *table_pointer_for_already_evac = &table_for_already_evac;

uint8_t *string_evac(uint8_t *);

/// The Infotable we use for strings
///
/// The entry should never be called, so we provide a panicking function
InfoTable table_for_string = {NULL, &string_evac};
static InfoTable *table_pointer_for_string = &table_for_string;

/// The InfoTable we use for string literals
InfoTable table_for_string_literal = {NULL, &static_evac};

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
  /// This is used to adjust the bottom of the stack, to implement updates
  uint8_t **base;
  /// A pointer to all of the data
  ///
  /// We keep this around so that we can free the stack on program exit
  uint8_t **data;
} StackA;

/// The "A" or argument stack
StackA g_SA = {NULL, NULL, NULL};

/// Represents an item on the secondary stack.
///
/// This is either a 64 bit integer, or a function
/// pointer for a continuation.
typedef union StackBItem {
  int64_t as_int;
  CodeLabel as_code;
  uint8_t *as_closure;
  union StackBItem *as_sb_base;
  uint8_t **as_sa_base;
} StackBItem;

/// Represents the secondary stack.
///
/// This contains various things: ints, and continuations.
typedef struct StackB {
  StackBItem *top;
  StackBItem *base;
  StackBItem *data;
} StackB;

/// The secondary stack
StackB g_SB = {NULL, NULL, NULL};

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
uint8_t *g_NodeRegister = (uint8_t *)&table_pointer_for_null;
/// The register holding a constructor closure to update
uint8_t *g_ConstrUpdateRegister = (uint8_t *)&table_pointer_for_null;

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

/// Write a short unsigned integer into the heap
void heap_write_uint16(uint16_t x) {
  heap_write(&x, sizeof(uint16_t));
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

static double HEAP_GROWTH = 3;

/// Collect a single root
void collect_root(uint8_t **root) {
  *root = read_info_table(*root)->evac(*root);
}

/// Grow the heap, removing useless objects
void collect_garbage(size_t extra_required) {
  Heap old = g_Heap;

  size_t new_capacity = HEAP_GROWTH * old.capacity;
  size_t required_capacity = old.cursor - old.data + extra_required;
  if (new_capacity < required_capacity) {
    new_capacity = required_capacity;
  }

  g_Heap.data = malloc(new_capacity * sizeof(uint8_t));
  if (g_Heap.data == NULL) {
    panic("Failed to allocate new heap during garbage collection");
  }
  g_Heap.cursor = g_Heap.data;
  g_Heap.capacity = new_capacity;

  if (g_StringRegister != NULL) {
    collect_root(&g_StringRegister);
  }
  if (g_NodeRegister != NULL) {
    collect_root(&g_NodeRegister);
  }

  for (uint8_t **p = g_SA.data; p < g_SA.top; ++p) {
    collect_root(p);
  }
  // Collect all the closures in the update frames
  for (StackBItem *base = g_SB.base; base != g_SB.data;
       base = base[0].as_sb_base) {
    collect_root(&base[2].as_closure);
  }
  // At this point, all references into the old heap are eliminated
  free(old.data);

  // To avoid exponential growth unnecessarily, we restrict
  // the actual capacity available, hiding some of the unused data
  size_t necessary_size = g_Heap.cursor - g_Heap.data;
  size_t comfortable_size = HEAP_GROWTH * necessary_size;
  if (comfortable_size < g_Heap.capacity) {
    g_Heap.capacity = comfortable_size;
  }
  DEBUG_PRINT("GC Done. 0x%05X ↓ 0x%05X ↑ 0x%05X\n", old.capacity,
              necessary_size, g_Heap.capacity);
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
    collect_garbage(amount);
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
  size_t min_size = sizeof(InfoTable *) + sizeof(uint8_t *);
  size_t extra = 0;
  // We need to make sure that the string has enough space for a relocation
  if (required < min_size) {
    extra = min_size - required;
    required += extra;
  }
  if (g_Heap.cursor + required > g_Heap.data + g_Heap.capacity) {
    // Push the two strings on the stack, so they're roots for the GC
    g_SA.top[0] = s1;
    g_SA.top[1] = s2;
    g_SA.top += 2;

    collect_garbage(required);

    data2 = g_SA.top[-1] + sizeof(InfoTable *);
    data1 = g_SA.top[-2] + sizeof(InfoTable *);
    g_SA.top -= 2;
  }

  uint8_t *ret = g_Heap.cursor;

  memcpy(g_Heap.cursor, &table_pointer_for_string, sizeof(InfoTable *));
  g_Heap.cursor += sizeof(InfoTable *);
  memcpy(g_Heap.cursor, data1, len1);
  g_Heap.cursor += len1;
  memcpy(g_Heap.cursor, data2, len2 + 1);
  g_Heap.cursor += len2 + 1;
  g_Heap.cursor += extra;

  return ret;
}

/// The evacuation function for strings
uint8_t *string_evac(uint8_t *base) {
  uint8_t *new_base = heap_cursor();
  size_t bytes = strlen((char *)(base + sizeof(InfoTable *))) + 1;
  heap_write(base, sizeof(InfoTable *) + bytes);
  // We need to make sure we also have enough space for the relocation
  if (bytes < sizeof(uint8_t *)) {
    g_Heap.cursor += sizeof(uint8_t *) - bytes;
  }
  memcpy(base, &table_pointer_for_already_evac, sizeof(InfoTable *));
  memcpy(base + sizeof(InfoTable *), &new_base, sizeof(uint8_t *));
  return new_base;
}

/// Save the current contents of the B stack
void save_SB() {
  g_SB.top[0].as_sb_base = g_SB.base;
  g_SB.base = g_SB.top;
  ++g_SB.top;
}

/// Save the current contents of the A stack
void save_SA() {
  g_SB.top[0].as_sa_base = g_SA.base;
  g_SA.base = g_SA.top;
  ++g_SB.top;
}

/// The code that gets called when we hit an update frame when we're expecting
/// a case continuation instead.
void *update_constructor() {
  // At this point, the topmost part of our update frame has been lobbed off,
  // now we need to chop off the rest, and also go to the "real" update
  // continuation
  g_SB.top -= 4;
  g_ConstrUpdateRegister = g_SB.top[3].as_closure;
  g_SA.base = g_SB.top[2].as_sa_base;
  g_SB.base = g_SB.top[1].as_sb_base;
  return g_SB.top[0].as_code;
}

/// The table we use when creating a partial application closure
InfoTable table_for_partial_application = {NULL, &static_evac};

/// Check if we need to create an application update.
///
/// This happens if insuffient arguments are passed to us on the stack.
///
/// We return either NULL, indicating that we need to continue, or
/// we return the codelabel to call next.
CodeLabel check_application_update(int64_t arg_count, CodeLabel current) {
  // NOTE: Be very careful to not create any temporaries that might get
  // invalidated by garbage collection before calling `h_reserve`!
  int64_t args = g_SA.top - g_SA.base;
  if (args >= arg_count) {
    return NULL;
  }
  // We don't want to pull out the closure just yet, it might get garbage
  // collected!
  StackBItem *saved_SB_base = g_SB.base[0].as_sb_base;
  uint8_t **saved_SA_base = g_SB.base[1].as_sa_base;

  // NOTE: Our stacks can't even contain 2^16 items.
  // This saves space in the partial application closure
  uint16_t b_items = g_SB.base - saved_SB_base;
  uint16_t a_items = g_SA.base - saved_SA_base;
  size_t saved_B_size = sizeof(StackBItem) * b_items;
  size_t saved_A_size = sizeof(uint8_t *) * a_items;
  size_t required =
      sizeof(InfoTable *) + sizeof(uint8_t *) + saved_B_size + saved_A_size;
  heap_reserve(required);

  uint8_t *closure = g_SB.base[2].as_closure;
  // Adjust stack by removing the update frame
  size_t above_frame = g_SB.top - g_SB.base + 4;
  for (size_t i = 0; i < above_frame; ++i) {
    g_SB.base[i] = g_SB.base[i + 4];
  }
  g_SB.top -= 4;
  // Restoring old stack bases
  g_SA.base = saved_SA_base;
  g_SB.base = saved_SB_base;

  // Constructing the new closure
  heap_write_info_table(&table_for_partial_application);
  heap_write_uint16(a_items);
  heap_write_uint16(b_items);
  // NOTE: this works in my mental model of C, but I am not a lawyer
  // heap_write uses memcpy under the hood
  heap_write(g_SA.base, saved_A_size);
  heap_write(g_SB.base, saved_B_size);

  // Replacing the old closure with an indirection
  // TODO

  // Return to the function that called us.
  return current;
}

/// The starting size for the Heap
static const size_t BASE_HEAP_SIZE = 1 << 7;
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

  g_SA.data = malloc(STACK_SIZE * sizeof(InfoTable *));
  if (g_SA.data == NULL) {
    panic("Failed to initialize Argument Stack");
  }
  g_SA.base = g_SA.data;
  g_SA.top = g_SA.data;

  g_SB.data = malloc(STACK_SIZE * sizeof(StackBItem));
  if (g_SB.data == NULL) {
    panic("Failed to initialize Secondary Stack");
  }
  g_SB.top = g_SB.data;
  g_SB.base = g_SB.data;
}

/// Cleanup all the memory areas that we've created
void cleanup() {
  free(g_Heap.data);
  free(g_SA.data);
  free(g_SB.data);
}
