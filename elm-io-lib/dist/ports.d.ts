/**
 * Port validation utility for Guida IO library.
 * Ensures all required ports are present in the Elm application.
 */
export interface ElmApp {
    ports: Record<string, unknown>;
}
/**
 * Validates that all required ports exist in the Elm application.
 * Throws an error if any port is missing.
 *
 * @param app - The initialized Elm application
 * @param portNames - Array of port names to check
 * @throws Error if ports are missing
 */
export declare function checkPortsExist(app: ElmApp, portNames: string[]): void;
/**
 * Type for outgoing port (Elm -> JS)
 */
export interface OutgoingPort<T> {
    subscribe: (callback: (data: T) => void) => void;
    unsubscribe: (callback: (data: T) => void) => void;
}
/**
 * Type for incoming port (JS -> Elm)
 */
export interface IncomingPort<T> {
    send: (data: T) => void;
}
/**
 * Standard response structure for call-and-response operations
 */
export interface Response<T = unknown> {
    id: string;
    type_: string;
    payload: T;
}
/**
 * Standard error payload structure
 */
export interface ErrorPayload {
    code: string;
    message: string;
    details?: unknown;
}
/**
 * Creates a standard OK response
 */
export declare function okResponse(id: string, payload?: unknown): Response;
/**
 * Creates a standard error response
 */
export declare function errorResponse(id: string, code: string, message: string, details?: unknown): Response<ErrorPayload>;
/**
 * Creates an error response from a caught exception
 */
export declare function errorFromException(id: string, error: unknown): Response<ErrorPayload>;
