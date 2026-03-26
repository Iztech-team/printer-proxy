from PIL import Image, ImageEnhance, ImageOps

from settings.config import ALLOWED_EXTENSIONS


def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def prepare_image_for_thermal(filepath: str, paper_width: int) -> str:
    img = Image.open(filepath)
    try:
        if img.mode == "RGBA" or "transparency" in img.info:
            background = Image.new("RGB", img.size, (255, 255, 255))
            if img.mode == "RGBA":
                background.paste(img, mask=img.split()[3])
            else:
                background.paste(img)
            img = background
        elif img.mode != "RGB":
            img = img.convert("RGB")

        if img.width > paper_width:
            ratio = paper_width / img.width
            new_height = int(img.height * ratio)
            img = img.resize((paper_width, new_height), Image.Resampling.LANCZOS)

        img = ImageOps.autocontrast(img, cutoff=0.5)
        img = ImageEnhance.Contrast(img).enhance(1.3)
        img = ImageEnhance.Sharpness(img).enhance(1.2)

        bw = img.convert("L")
        gamma = 0.9
        lut = [min(255, int(255 * ((i / 255.0) ** gamma))) for i in range(256)]
        bw = bw.point(lut)
        bw = bw.point(lambda x: 255 if x > 245 else x)
        img = bw.convert("1", dither=Image.Dither.FLOYDSTEINBERG)
        img.save(filepath, "PNG")
    finally:
        img.close()
    return filepath
