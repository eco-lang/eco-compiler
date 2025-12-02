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
export function checkPortsExist(app: ElmApp, portNames: string[]): void {
    if (!app.ports) {
        throw new Error("The Elm application has no ports.");
    }

    const allPorts = `[${Object.keys(app.ports).sort().join(", ")}]`;

    for (const portName of portNames) {
        if (!Object.prototype.hasOwnProperty.call(app.ports, portName)) {
            throw new Error(
                `Could not find a port named "${portName}" among: ${allPorts}`
            );
        }
    }
}

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
export function okResponse(id: string, payload: unknown = null): Response {
    return {
        id,
        type_: "Ok",
        payload,
    };
}

/**
 * Creates a standard error response
 */
export function errorResponse(
    id: string,
    code: string,
    message: string,
    details?: unknown
): Response<ErrorPayload> {
    return {
        id,
        type_: "Error",
        payload: {
            code,
            message,
            details,
        },
    };
}

/**
 * Creates an error response from a caught exception
 */
export function errorFromException(id: string, error: unknown): Response<ErrorPayload> {
    if (error instanceof Error) {
        const nodeError = error as NodeJS.ErrnoException;
        return errorResponse(
            id,
            nodeError.code || "UNKNOWN",
            nodeError.message,
            {
                name: error.name,
                stack: error.stack,
            }
        );
    }
    return errorResponse(id, "UNKNOWN", String(error));
}
