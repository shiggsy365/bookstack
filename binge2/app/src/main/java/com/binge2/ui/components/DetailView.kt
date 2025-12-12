package com.binge2.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import com.binge2.ui.theme.Background

@Composable
fun DetailView(
    title: String,
    overview: String,
    backdropUrl: String?,
    logoUrl: String?,
    releaseDate: String?,
    seasonNumber: Int? = null,
    episodeNumber: Int? = null,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier.fillMaxSize()
    ) {
        // Backdrop image with blur
        AsyncImage(
            model = backdropUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxSize()
                .blur(20.dp)
        )

        // Gradient overlay
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            Color.Transparent,
                            Background.copy(alpha = 0.7f),
                            Background
                        ),
                        startY = 0f,
                        endY = 1000f
                    )
                )
        )

        // Content
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(48.dp),
            verticalArrangement = Arrangement.Bottom
        ) {
            // Logo or Title
            if (logoUrl != null) {
                AsyncImage(
                    model = logoUrl,
                    contentDescription = title,
                    modifier = Modifier
                        .height(120.dp)
                        .padding(bottom = 16.dp)
                )
            } else {
                Text(
                    text = title,
                    style = MaterialTheme.typography.displayMedium,
                    color = Color.White,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            // Metadata
            Row(
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.padding(bottom = 16.dp)
            ) {
                releaseDate?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.titleMedium,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                }
                if (seasonNumber != null && episodeNumber != null) {
                    Text(
                        text = "S${seasonNumber} E${episodeNumber}",
                        style = MaterialTheme.typography.titleMedium,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                }
            }

            // Overview
            Text(
                text = overview,
                style = MaterialTheme.typography.bodyLarge,
                color = Color.White.copy(alpha = 0.9f),
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 800.dp)
            )
        }
    }
}
