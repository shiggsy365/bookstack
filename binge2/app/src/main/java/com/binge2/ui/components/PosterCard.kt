package com.binge2.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.MaterialTheme
import coil.compose.AsyncImage
import com.binge2.ui.theme.FocusBorder
import com.binge2.ui.theme.UnfocusedBorder

@Composable
fun PosterCard(
    posterUrl: String?,
    title: String,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
    aspectRatio: Float = 2f / 3f
) {
    Card(
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = modifier
            .width(150.dp)
            .aspectRatio(aspectRatio),
        colors = CardDefaults.colors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        ),
        border = CardDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(3.dp, FocusBorder)
            ),
            pressedBorder = Border(
                border = BorderStroke(3.dp, FocusBorder)
            )
        ),
        scale = CardDefaults.scale(
            focusedScale = 1.05f
        )
    ) {
        AsyncImage(
            model = posterUrl ?: "",
            contentDescription = title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize()
        )
    }
}
