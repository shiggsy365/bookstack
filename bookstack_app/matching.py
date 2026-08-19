import re


def normalize_title(title):
    return re.sub(r'\s+', ' ', re.sub(r'\([^)]*\)', '', title or '')).strip().lower()


def title_words(title):
    return {
        word.strip(',.;:!?/')
        for word in normalize_title(title).split()
        if word.strip(',.;:!?/')
    }
