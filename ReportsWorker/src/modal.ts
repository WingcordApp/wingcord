// Discord's forms (modals): building them, and reading what comes back.
// Every field sits in a Label, as Discord now asks; a form holds five at most.
// Discord's limits are enforced here, so no form can be refused for a long
// title or a prefilled value: a refused form is a press that does nothing.

const LABEL = 18;
const TEXT_INPUT = 4;
const STRING_SELECT = 3;
const FILE_UPLOAD = 19;
const CHECKBOX = 23;

export const SHORT = 1;
export const PARAGRAPH = 2;

export interface Modal {
	custom_id: string;
	title: string;
	components: unknown[];
}

export interface SelectOption {
	label: string;
	value: string;
	description?: string;
	default?: boolean;
}

/** A form: at most 45 characters of title, five fields. */
export function modal(customId: string, title: string, fields: unknown[]): Modal {
	return { custom_id: customId, title: units(title, 45), components: fields.slice(0, 5) };
}

export function label(text: string, description: string | null, component: unknown): unknown {
	const field: Record<string, unknown> = { type: LABEL, label: units(text, 45), component };
	if (description) field.description = units(description, 100);
	return field;
}

export function textInput(
	customId: string,
	style: typeof SHORT | typeof PARAGRAPH,
	options: { value?: string | null; required?: boolean; maxLength?: number; placeholder?: string } = {},
): unknown {
	const maxLength = Math.min(options.maxLength ?? 4000, 4000);
	const input: Record<string, unknown> = {
		type: TEXT_INPUT,
		custom_id: customId,
		style,
		required: options.required ?? true,
		max_length: maxLength,
	};
	if (options.value) input.value = units(options.value, maxLength);
	if (options.placeholder) input.placeholder = units(options.placeholder, 100);
	return input;
}

export function stringSelect(
	customId: string,
	options: SelectOption[],
	settings: { required?: boolean; placeholder?: string } = {},
): unknown {
	const select: Record<string, unknown> = {
		type: STRING_SELECT,
		custom_id: customId,
		options: options.slice(0, 25).map((option) => ({
			...option,
			label: units(option.label, 100),
			value: units(option.value, 100),
			...(option.description ? { description: units(option.description, 100) } : {}),
		})),
		required: settings.required ?? true,
	};
	if (settings.required === false) select.min_values = 0;
	if (settings.placeholder) select.placeholder = units(settings.placeholder, 150);
	return select;
}

export function checkbox(customId: string, checked = false): unknown {
	return { type: CHECKBOX, custom_id: customId, default: checked };
}

/** Files to attach: `fileTypes` matches extensions only (".png"), as Discord does. */
export function fileUpload(customId: string, fileTypes: string[], required = false): unknown {
	const upload: Record<string, unknown> = {
		type: FILE_UPLOAD,
		custom_id: customId,
		required,
		max_values: 1,
		file_types: fileTypes,
	};
	if (!required) upload.min_values = 0;
	return upload;
}

// MARK: Reading a submitted form

export interface Submitted {
	type: number;
	custom_id?: string;
	value?: string | boolean | null;
	values?: string[];
	component?: Submitted;
	components?: Submitted[];
}

/** Every answered field by its id, from Labels and from the older Action Rows alike. */
export function answers(components: Submitted[] | undefined): Map<string, Submitted> {
	const found = new Map<string, Submitted>();
	const visit = (component: Submitted) => {
		if (component.component) visit(component.component);
		for (const child of component.components ?? []) visit(child);
		if (component.custom_id) found.set(component.custom_id, component);
	};
	for (const component of components ?? []) visit(component);
	return found;
}

export function text(answered: Map<string, Submitted>, id: string): string {
	const value = answered.get(id)?.value;
	return typeof value === "string" ? value : "";
}

export function chosen(answered: Map<string, Submitted>, id: string): string | null {
	return answered.get(id)?.values?.[0] ?? null;
}

export function ticked(answered: Map<string, Submitted>, id: string): boolean {
	return answered.get(id)?.value === true;
}

/** The ids of the files given, resolved through the interaction's `resolved.attachments`. */
export function files(answered: Map<string, Submitted>, id: string): string[] {
	return answered.get(id)?.values ?? [];
}

/**
 * At most `limit` UTF-16 units — how Discord counts — never splitting a
 * character in two.
 */
export function units(value: string, limit: number): string {
	if (value.length <= limit) return value;
	let cut = value.slice(0, limit - 1);
	if (/[\uD800-\uDBFF]$/.test(cut)) cut = cut.slice(0, -1);
	return `${cut}…`;
}
