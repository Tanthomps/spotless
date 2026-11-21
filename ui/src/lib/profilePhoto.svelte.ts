// A profile photo of your own (the iPhone has the same, Screens/YouTubeSignIn.swift ProfilePhoto):
// square-cropped to 256 px and kept on this Mac (localStorage). It wins over the account picture.
import { browser } from '$app/environment';

const KEY = 'spotless:profile-photo';

function load(): string | null {
	if (!browser) return null;
	try {
		return localStorage.getItem(KEY);
	} catch {
		return null;
	}
}

export const profilePhoto = $state({ url: load() });

/** Pick a picture, crop the middle square, store it. Resolves false when nothing was set. */
export function chooseProfilePhoto(): Promise<boolean> {
	return new Promise((resolve) => {
		const input = document.createElement('input');
		input.type = 'file';
		input.accept = 'image/*';
		input.onchange = async () => {
			const file = input.files?.[0];
			if (!file) return resolve(false);
			try {
				const bmp = await createImageBitmap(file);
				const side = Math.min(bmp.width, bmp.height);
				const c = document.createElement('canvas');
				c.width = c.height = 256;
				c.getContext('2d')!.drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, 256, 256);
				const url = c.toDataURL('image/jpeg', 0.9);
				localStorage.setItem(KEY, url);
				profilePhoto.url = url;
				resolve(true);
			} catch {
				resolve(false);
			}
		};
		input.click();
	});
}

export function removeProfilePhoto() {
	try {
		localStorage.removeItem(KEY);
	} catch {
		/* private mode: it was never stored */
	}
	profilePhoto.url = null;
}
