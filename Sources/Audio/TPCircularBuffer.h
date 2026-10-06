//
//  TPCircularBuffer.h
//  Circular/Ring buffer implementation
//
//  https://github.com/michaeltyson/TPCircularBuffer
//
//  Created by Michael Tyson on 10/12/2011.
//
//  Copyright (C) 2012-2013 A Tasty Pixel
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#ifndef TPCircularBuffer_h
#define TPCircularBuffer_h

#include <stdbool.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void             *buffer;
    int32_t           length;
    int32_t           tail;
    int32_t           head;
    volatile int32_t  fillCount;
    bool              atomic;
} TPCircularBuffer;

bool  TPCircularBufferInit(TPCircularBuffer *buffer, int32_t length);
void  TPCircularBufferCleanup(TPCircularBuffer *buffer);
void  TPCircularBufferClear(TPCircularBuffer *buffer);

static __inline__ __attribute__((always_inline)) int32_t TPCircularBufferGetAvailableSpace(TPCircularBuffer *buffer, int32_t *availableBytes) {
    if ( availableBytes ) *availableBytes = buffer->length - buffer->fillCount;
    return buffer->length - buffer->fillCount;
}

static __inline__ __attribute__((always_inline)) bool TPCircularBufferProduce(TPCircularBuffer *buffer, const void* src, int32_t len) {
    if ( len == 0 ) return true;
    if ( buffer->length - buffer->fillCount < len ) return false;
    
    int32_t tail = buffer->tail;
    int32_t bytesToEnd = buffer->length - tail;
    
    if ( bytesToEnd >= len ) {
        memcpy((char*)buffer->buffer + tail, src, len);
    } else {
        memcpy((char*)buffer->buffer + tail, src, bytesToEnd);
        memcpy((char*)buffer->buffer, (char*)src + bytesToEnd, len - bytesToEnd);
    }
    
    buffer->tail = (tail + len) % buffer->length;
    if ( buffer->atomic ) {
        __sync_fetch_and_add(&buffer->fillCount, len);
    } else {
        buffer->fillCount += len;
    }
    
    return true;
}

static __inline__ __attribute__((always_inline)) void* TPCircularBufferHead(TPCircularBuffer *buffer, int32_t* availableBytes) {
    if ( availableBytes ) *availableBytes = buffer->fillCount;
    if ( buffer->fillCount == 0 ) return NULL;
    return (char*)buffer->buffer + buffer->head;
}

static __inline__ __attribute__((always_inline)) void TPCircularBufferConsume(TPCircularBuffer *buffer, int32_t amount) {
    if ( amount == 0 ) return;
    
    int32_t head = buffer->head;
    
    buffer->head = (head + amount) % buffer->length;
    if ( buffer->atomic ) {
        __sync_fetch_and_sub(&buffer->fillCount, amount);
    } else {
        buffer->fillCount -= amount;
    }
}

static __inline__ __attribute__((always_inline)) bool TPCircularBufferConsumeToBuffer(TPCircularBuffer *buffer, void* dst, int32_t len) {
    if ( len == 0 ) return true;
    if ( buffer->fillCount < len ) return false;
    
    int32_t head = buffer->head;
    int32_t bytesToEnd = buffer->length - head;
    
    if ( bytesToEnd >= len ) {
        memcpy(dst, (char*)buffer->buffer + head, len);
    } else {
        memcpy(dst, (char*)buffer->buffer + head, bytesToEnd);
        memcpy((char*)dst + bytesToEnd, (char*)buffer->buffer, len - bytesToEnd);
    }
    
    buffer->head = (head + len) % buffer->length;
    if ( buffer->atomic ) {
        __sync_fetch_and_sub(&buffer->fillCount, len);
    } else {
        buffer->fillCount -= len;
    }
    
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
