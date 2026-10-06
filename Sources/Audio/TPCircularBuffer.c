//
//  TPCircularBuffer.c
//

#include "TPCircularBuffer.h"
#include <mach/mach.h>
#include <stdlib.h>



bool TPCircularBufferInit(TPCircularBuffer *buffer, int32_t length) {
    // Keep it simple for this implementation: standard malloc without Mach virtual memory tricks
    // This is a simplified fallback that still works atomically for single-producer/single-consumer
    buffer->length = length;
    buffer->fillCount = 0;
    buffer->head = buffer->tail = 0;
    buffer->atomic = true;
    
    buffer->buffer = malloc(length);
    if ( !buffer->buffer ) {
        return false;
    }
    
    return true;
}

void TPCircularBufferCleanup(TPCircularBuffer *buffer) {
    if ( buffer->buffer ) {
        free(buffer->buffer);
        buffer->buffer = NULL;
    }
}

void TPCircularBufferClear(TPCircularBuffer *buffer) {
    buffer->fillCount = 0;
    buffer->head = buffer->tail = 0;
}
