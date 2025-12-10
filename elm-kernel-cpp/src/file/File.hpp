#ifndef ECO_FILE_HPP
#define ECO_FILE_HPP

/**
 * Elm Kernel File Module - Runtime Heap Integration
 *
 * Provides file operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific file dialogs.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../core/Scheduler.hpp"
#include "../json/Json.hpp"

namespace Elm::Kernel::File {

using TaskPtr = Scheduler::TaskPtr;
using DecoderPtr = Json::DecoderPtr;

/**
 * JSON decoder for File values.
 * Used for decoding files from form submissions and drag/drop events.
 */
DecoderPtr decoder();

/**
 * Make bytes safe for Internet Explorer (compatibility shim).
 * In modern browsers, this is a no-op that returns the input unchanged.
 */
HPointer makeBytesSafeForInternetExplorer(HPointer bytes);

/**
 * Get the name of a file.
 * @param file A File value
 * @return String with the file name
 */
HPointer name(void* file);

/**
 * Get the MIME type of a file.
 * @param file A File value
 * @return String with the MIME type
 */
HPointer mime(void* file);

/**
 * Get the size of a file in bytes.
 * @param file A File value
 * @return Int with the file size
 */
HPointer size(void* file);

/**
 * Get the last modified time of a file.
 * @param file A File value
 * @return Posix time (Int) of last modification
 */
HPointer lastModified(void* file);

/**
 * Read file contents as a string.
 * @param file A File value
 * @return Task that produces String
 */
TaskPtr toString(void* file);

/**
 * Read file contents as bytes.
 * @param file A File value
 * @return Task that produces Bytes
 */
TaskPtr toBytes(void* file);

/**
 * Read file contents as a data URL.
 * @param file A File value
 * @return Task that produces String (data: URL)
 */
TaskPtr toUrl(void* file);

/**
 * Open file selector for single file.
 * @param mimeTypes List of acceptable MIME types
 * @return Task that produces Maybe File
 */
TaskPtr uploadOne(void* mimeTypes);

/**
 * Open file selector for one or more files.
 * @param mimeTypes List of acceptable MIME types
 * @return Task that produces (File, List File)
 */
TaskPtr uploadOneOrMore(void* mimeTypes);

/**
 * Download string content as a file.
 * @param fileName Name for the downloaded file
 * @param mimeType MIME type of the content
 * @param content String content to download
 * @return Task that produces ()
 */
TaskPtr download(void* fileName, void* mimeType, void* content);

/**
 * Download a URL as a file.
 * @param fileName Name for the downloaded file
 * @param url URL to download
 * @return Task that produces ()
 */
TaskPtr downloadUrl(void* fileName, void* url);

} // namespace Elm::Kernel::File

#endif // ECO_FILE_HPP
