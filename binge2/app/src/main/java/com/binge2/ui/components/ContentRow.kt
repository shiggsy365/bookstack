package com.binge2.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.tv.foundation.lazy.list.TvLazyRow
import androidx.tv.foundation.lazy.list.items
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.binge2.ui.theme.OnSurface

@Composable
fun <T> ContentRow(
    title: String,
    items: List<T>,
    onItemClick: (T) -> Unit,
    onItemLongClick: (T) -> Unit,
    onItemFocused: (T) -> Unit,
    posterUrl: (T) -> String?,
    itemTitle: (T) -> String,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.padding(vertical = 12.dp)
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge,
            color = OnSurface,
            modifier = Modifier.padding(start = 48.dp, bottom = 12.dp)
        )

        TvLazyRow(
            contentPadding = PaddingValues(horizontal = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            items(items) { item ->
                PosterCard(
                    posterUrl = posterUrl(item),
                    title = itemTitle(item),
                    onClick = { onItemClick(item) },
                    onLongClick = { onItemLongClick(item) },
                    modifier = Modifier.onFocusChanged { focusState ->
                        if (focusState.isFocused) {
                            onItemFocused(item)
                        }
                    }
                )
            }
        }
    }
}

import androidx.compose.ui.focus.onFocusChanged
