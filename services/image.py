from PIL import Image, ImageEnhance, ImageOps

from settings.config import ALLOWED_EXTENSIONS


def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def prepare_image_for_thermal(filepath: str, paper_width: int, fast: bool = True) -> str:
    img = Image.open(filepath)
    try:
        # 1. Transparency → white background
        if img.mode == "RGBA" or "transparency" in img.info:
            background = Image.new("RGB", img.size, (255, 255, 255))
            if img.mode == "RGBA":
                background.paste(img, mask=img.split()[3])
            else:
                background.paste(img)
            img = background
        elif img.mode != "RGB":
            img = img.convert("RGB")

        # 2. Resize to paper width
        if img.width != paper_width:
            ratio = paper_width / img.width
            new_height = int(img.height * ratio)
            img = img.resize((paper_width, new_height), Image.Resampling.LANCZOS)

        # 3. Auto-contrast — stretch histogram, clip 0.5% extremes
        img = ImageOps.autocontrast(img, cutoff=0.5)

        # 4. Contrast boost — 30% increase
        img = ImageEnhance.Contrast(img).enhance(1.3)

        # 5. Sharpness boost — 20% increase
        img = ImageEnhance.Sharpness(img).enhance(1.2)

        # 6. Grayscale
        img = img.convert("L")

        # 7. Gamma correction — 0.9 brightens midtones slightly
        gamma = 0.9
        lut = [min(255, int(255 * ((i / 255.0) ** gamma))) for i in range(256)]
        img = img.point(lut)

        # 8. Near-white cleanup — snap faint grays to pure white
        img = img.point(lambda x: 255 if x > 245 else x)

        # 9. Floyd-Steinberg dithering to 1-bit
        img = img.convert("1", dither=Image.Dither.FLOYDSTEINBERG)

        img.save(filepath, "PNG")
    finally:
        img.close()
    return filepath
