from PIL import Image, ImageOps

from settings.config import ALLOWED_EXTENSIONS


def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def prepare_image_for_thermal(filepath: str, paper_width: int, fast: bool = True) -> str:
    """Optimize an image for thermal printing.

    Converts to 1-bit black/white using Floyd-Steinberg dithering.
    This is what thermal printers natively understand — each dot is either
    burned (black) or not (white). Dithering simulates grayscale by varying
    the density of black dots.

    Args:
        filepath: Path to the image file (modified in-place).
        paper_width: Target width in pixels (e.g. 510 for 80mm paper).
        fast: If True, reduce resolution for faster printing.
    """
    img = Image.open(filepath)
    try:
        # Handle transparency — replace with white background
        if img.mode == "RGBA" or "transparency" in img.info:
            background = Image.new("RGB", img.size, (255, 255, 255))
            if img.mode == "RGBA":
                background.paste(img, mask=img.split()[3])
            else:
                background.paste(img)
            img = background
        elif img.mode != "RGB":
            img = img.convert("RGB")

        # Resize to fill full paper width
        if img.width != paper_width:
            ratio = paper_width / img.width
            new_height = int(img.height * ratio)
            img = img.resize((paper_width, new_height), Image.Resampling.LANCZOS)

        # Convert to grayscale
        img = img.convert("L")

        # Auto-contrast to use full brightness range
        img = ImageOps.autocontrast(img, cutoff=1)

        # Convert to 1-bit with Floyd-Steinberg dithering
        # This produces the best visual quality on thermal printers —
        # it simulates grayscale by distributing black dots proportionally
        img = img.convert("1", dither=Image.Dither.FLOYDSTEINBERG)

        img.save(filepath, "PNG")
    finally:
        img.close()
    return filepath
